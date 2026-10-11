"""Phase 3 — 로컬 승격분을 운영 Supabase에 업로드.

로컬 collected_products는 운영에 올라가지 않는다. 승격된 product_masters/barcodes만
운영에 올린다. 쓰기는 **운영 RPC `upload_promoted_product`** 로만 한다 (0016 마이그레이션):
  - master upsert(verified 가드) + barcode 연결을 한 트랜잭션에서 (원자성)
  - verified 가드를 변경문에 박아 read-then-write 경쟁 제거
  - 따라서 클라이언트는 직접 INSERT/PATCH 하지 않는다 (HIGH 1·2 대응)

범위:
  - 기본: stage='promoted' 이고 prod_master_id 가 NULL 인 행이 하나라도 있는 master (미연결분만)
  - --ids: 그 collected_products.id 중 승격 행의 master 만
  - --all: 이미 연결된 master 포함 모든 승격 master
  고른 master 는 이미 연결된 형제 행을 포함해 그 master 의 모든 승격 바코드를 보낸다.

영수증: master 하나의 RPC 가 끝나면 LOCAL 트랜잭션 하나로 바코드(행)마다 upload_receipts 에 결과를
남기고, 운영에 실제로 붙은 행(inserted·existing·exists)에만 collected_products.prod_master_id 를
기록해 커밋한다. 업로드가 읽은 승격 세대(promoted_at)·바코드가 그대로일 때만 기록한다. RPC 가
실패하면 그 master 의 행마다 error 영수증을 남기고 다음 master 로 넘어간다. 중간에 멈춰도 다음
기본 실행이 미연결분만 다시 보내고, RPC(0021)가 이미 된 연결을 exists 로 돌려줘 기록이 채워진다.

이미지: image_url 이 비어있는 승격 바코드는 prepare_images.py 가 정리한 JPEG(manifest 의
local_path)를 운영 Storage(product-images)의 products/<barcode>-<업로드 바이트 SHA-256 앞 16자>.jpg
경로에 덮어쓰기 없이(x-upsert 없음) 올리고 그 공개 URL 을 image_url 로 채워 RPC payload 에 실어
보낸다. 운영이 그 바코드를 실제로 새로 받은(바코드 결과 inserted) 경우에만 로컬
product_barcodes.image_url 에 되쓴다. (Storage 업로드는 SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY
필요 — 없으면 image 단계만 건너뛴다.)

배포 순서: ① 운영 Supabase 에 0021 마이그레이션 → ② LOCAL 에 pipeline/sql/upload_receipts.sql DDL →
③ 이 코드. 실행 시 LOCAL 에 upload_receipts 가 없으면 RPC 를 하나도 부르지 않고 멈추고, 운영 RPC 가
0021 밖의 master 결과(예: 0020 의 updated)를 돌려주면 그 master 의 LOCAL 기록 전에 멈춘다.

백엔드 2종 (둘 다 같은 RPC 호출):
  - REST (기본): SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY (DB 비번 불필요)
  - postgres: --target-dsn (운영 DB 연결문자열)

--dry-run: 쓰기 없이 운영을 읽어 각 master/barcode가 어떻게 처리될지 분류만 보여준다.

사용:
  .venv/bin/python upload_prod.py --dry-run
  .venv/bin/python upload_prod.py
  .venv/bin/python upload_prod.py --ids <uuid,uuid>
  .venv/bin/python upload_prod.py --all
  .venv/bin/python upload_prod.py --target-dsn <dsn>
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import urllib.error
import urllib.request
import uuid
from collections import Counter
from datetime import datetime

import psycopg

from common import connect

MASTER_COLS = [
    "brand", "name", "category", "ingredients_raw", "ingredients_tokens",
    "bad_ingredients_detected", "good_ingredients_detected", "verdict_reason_codes",
    "verdict", "rule_version", "computed_at", "source", "source_url",
    "source_checked_at", "verified_status",
]


def master_key(brand, name, ingredients_raw):
    """운영 product_masters.master_key(0019, UNIQUE)와 같은 식 — brand|name|ingredients_raw."""
    return hashlib.md5(f"{brand}|{name}|{ingredients_raw}".encode()).hexdigest()


def ingredients_hash(brand, ingredients_raw):
    """운영 product_masters.ingredients_hash(일반 인덱스)와 같은 식 — brand|ingredients_raw."""
    return hashlib.md5(f"{brand}|{ingredients_raw}".encode()).hexdigest()


def renamed_owner_id(owners, vals):
    """입력 바코드 소유 master 중 '이름만 바뀐 같은 상품'(같은 ingredients_hash, 다른 master_key)의
    id. RPC(0020) renamed_held 가드와 같은 판정. owners: [(master_id, ingredients_hash, master_key)]"""
    ih = ingredients_hash(vals["brand"], vals["ingredients_raw"])
    mk = master_key(vals["brand"], vals["name"], vals["ingredients_raw"])
    for mid, oih, omk in owners:
        if oih == ih and omk != mk:
            return mid
    return None


def _jsonable(v):
    return v.isoformat() if isinstance(v, datetime) else v


def fetch_promoted(src, *, ids=None, all_=False):
    """승격된 master(중복 제거) + master별 barcode 목록 + 건너뛴 id 목록.

    범위(master id 집합을 먼저 SQL로 정한다):
      - ids: 그 collected_products.id 중 stage='promoted' 행의 promoted_master_id
      - all_: 모든 승격 master
      - 기본: stage='promoted' 이고 prod_master_id 가 NULL 인 행이 하나라도 있는 master
    고른 master 는 이미 연결된 형제 행을 포함해 모든 승격 행의 바코드를 돌려준다.
    skipped: ids 중 승격이 아니거나 없는 id (문자열)."""
    skipped: list = []
    with src.cursor() as cur:
        if ids is not None:
            ids = [str(i) for i in ids]
            if not ids:
                return {}, {}, []
            cur.execute("""
                select id::text, promoted_master_id from collected_products
                where id = any(%s::uuid[]) and stage = 'promoted' and promoted_master_id is not null
            """, (ids,))
            found = {r[0]: r[1] for r in cur.fetchall()}
            skipped = [i for i in ids if i not in found]
            master_ids = sorted(set(found.values()), key=str)
        else:
            cond = "" if all_ else "and prod_master_id is null"
            cur.execute(f"""
                select distinct promoted_master_id from collected_products
                where stage = 'promoted' and promoted_master_id is not null {cond}
            """)
            master_ids = [r[0] for r in cur.fetchall()]
        if not master_ids:
            return {}, {}, skipped
        cur.execute(f"""
            select distinct m.id, {', '.join('m.' + c for c in MASTER_COLS)}
            from product_masters m
            join collected_products c on c.promoted_master_id = m.id
            where c.stage = 'promoted' and m.id = any(%s)
        """, (master_ids,))
        masters = {r[0]: dict(zip(MASTER_COLS, (_jsonable(x) for x in r[1:]))) for r in cur.fetchall()}
        # collected row 식별자(id)를 함께 들고 온다 — writeback을 행 단위로 좁히기 위해.
        # barcode가 collected_products에서 유니크하지 않으므로 (b.master_id =
        # c.promoted_master_id)까지 묶어 그 행의 바코드만 매칭한다.
        cur.execute("""
            select c.promoted_master_id, c.id, c.barcode, b.size, b.image_url, b.image_source_url,
                   c.promoted_at
            from collected_products c
            join product_barcodes b
              on b.barcode = c.barcode and b.master_id = c.promoted_master_id
            where c.stage = 'promoted' and c.promoted_master_id = any(%s)
        """, (master_ids,))
        bc_by_master: dict = {}
        for mid, cid, barcode, size, iu, isu, pat in cur.fetchall():
            bc_by_master.setdefault(mid, []).append(
                {"collected_id": cid, "barcode": barcode, "size": size,
                 "image_url": iu, "image_source_url": isu, "promoted_at": pat})
    return masters, bc_by_master, skipped


# ── REST 백엔드 ───────────────────────────────────────────────────────────────
class RestTarget:
    def __init__(self):
        url = os.environ.get("SUPABASE_URL", "").strip('"').rstrip("/")
        key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "").strip('"')
        if not url or not key:
            raise SystemExit("error: SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY 필요")
        self.base, self.key = f"{url}/rest/v1", key

    def _req(self, method, path, body=None):
        req = urllib.request.Request(self.base + path, method=method)
        req.add_header("apikey", self.key)
        req.add_header("Authorization", f"Bearer {self.key}")
        req.add_header("Content-Type", "application/json")
        data = json.dumps(body).encode() if body is not None else None
        try:
            with urllib.request.urlopen(req, data=data) as resp:
                raw = resp.read().decode()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"{method} {path} → {e.code} {e.read().decode()[:200]}")

    def plan_master(self, vals):
        h = master_key(vals["brand"], vals["name"], vals["ingredients_raw"])
        rows = self._req("GET", f"/product_masters?master_key=eq.{h}&select=id,verified_status")
        if not rows:
            return None, None
        return rows[0]["id"], rows[0]["verified_status"]

    def barcode_owner(self, barcode):
        rows = self._req("GET", f"/product_barcodes?barcode=eq.{barcode}&select=master_id")
        return rows[0]["master_id"] if rows else None

    def barcode_owner_masters(self, barcodes):
        if not barcodes:
            return []
        rows = self._req("GET", "/product_barcodes?barcode=in.(" + ",".join(barcodes) + ")"
                         "&select=master_id,product_masters(ingredients_hash,master_key)")
        return [(r["master_id"], r["product_masters"]["ingredients_hash"],
                 r["product_masters"]["master_key"]) for r in rows or []]

    def upload(self, master, barcodes):
        return self._req("POST", "/rpc/upload_promoted_product",
                         {"p_master": master, "p_barcodes": barcodes})


# ── postgres 백엔드 (같은 RPC) ────────────────────────────────────────────────
class PgTarget:
    def __init__(self, dsn):
        self.conn = psycopg.connect(dsn)

    def plan_master(self, vals):
        with self.conn.cursor() as cur:
            cur.execute("select id, verified_status::text from product_masters "
                        "where master_key = md5(%s||'|'||%s||'|'||%s)",
                        (vals["brand"], vals["name"], vals["ingredients_raw"]))
            r = cur.fetchone()
            return (None, None) if not r else (r[0], r[1])

    def barcode_owner(self, barcode):
        with self.conn.cursor() as cur:
            cur.execute("select master_id from product_barcodes where barcode=%s", (barcode,))
            r = cur.fetchone()
            return r[0] if r else None

    def barcode_owner_masters(self, barcodes):
        with self.conn.cursor() as cur:
            cur.execute("""select b.master_id, m.ingredients_hash, m.master_key
                           from product_barcodes b join product_masters m on m.id = b.master_id
                           where b.barcode = any(%s)""", (list(barcodes),))
            return cur.fetchall()

    def upload(self, master, barcodes):
        # 실패하면 rollback 해 연결을 실패 트랜잭션 상태로 남기지 않는다 — 남기면 뒤 master 가 모두 실패한다.
        try:
            with self.conn.cursor() as cur:
                cur.execute("select public.upload_promoted_product(%s::jsonb, %s::jsonb)",
                            (json.dumps(master), json.dumps(barcodes)))
                res = cur.fetchone()[0]
            self.conn.commit()
        except BaseException:
            self.conn.rollback()
            raise
        return res


# ── Storage 이미지 업로드 ─────────────────────────────────────────────────────
# prepare_images.py 가 정리한 JPEG(work/images/products/<barcode>.jpg)와 manifest 를
# 입력으로, image_url 이 비어있는 승격 바코드만 운영 Storage 에 올리고 공개 URL 을
# image_url 에 채운다. (plan §6.4 ③ — 이미지 업로드 + image_url 갱신)
STORAGE_BUCKET = "product-images"
IMAGE_MANIFEST = os.path.join(os.path.dirname(__file__), "work", "images", "manifest.json")


def load_image_manifest() -> dict:
    """prepare_images.py 산출 manifest → {barcode: entry}. 없으면 빈 dict."""
    if not os.path.exists(IMAGE_MANIFEST):
        return {}
    with open(IMAGE_MANIFEST, encoding="utf-8") as f:
        return {e["barcode"]: e for e in json.load(f)}


def image_object_path(barcode, data: bytes) -> str:
    """올릴 바이트의 SHA-256 앞 16자로 만든 Storage 객체 경로. 내용이 같으면 경로가 같고 다르면 달라서,
    운영이 이미 참조하는 객체를 덮어쓰지 않는다."""
    return f"products/{barcode}-{hashlib.sha256(data).hexdigest()[:16]}.jpg"


def storage_already_exists(status: int, body: str) -> bool:
    """Storage 가 '이미 있는 경로'라고 답했는지. 경로가 내용 해시라 이미 있으면 같은 내용이다."""
    return status == 409 or (status == 400 and ("Duplicate" in body or "already exists" in body))


class StorageUploader:
    """RestTarget 과 같은 자격증명(SUPABASE_URL + SERVICE_ROLE_KEY)을 urllib 로 써서
    Storage 에 JPEG 를 업로드하고 공개 URL 을 돌려준다. x-upsert 없이 올리므로 기존 객체를 덮어쓰지 않는다."""

    def __init__(self):
        self.url = os.environ.get("SUPABASE_URL", "").strip('"').rstrip("/")
        self.key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "").strip('"')
        self.enabled = bool(self.url and self.key)

    def public_url(self, storage_target: str) -> str:
        return f"{self.url}/storage/v1/object/public/{STORAGE_BUCKET}/{storage_target}"

    def upload_bytes(self, data: bytes, object_path: str) -> str:
        req = urllib.request.Request(
            f"{self.url}/storage/v1/object/{STORAGE_BUCKET}/{object_path}",
            method="POST", data=data)
        req.add_header("apikey", self.key)
        req.add_header("Authorization", f"Bearer {self.key}")
        req.add_header("Content-Type", "image/jpeg")
        try:
            with urllib.request.urlopen(req) as resp:
                resp.read()
        except urllib.error.HTTPError as e:
            body = e.read().decode(errors="replace")
            if storage_already_exists(e.code, body):
                return self.public_url(object_path)
            raise RuntimeError(f"storage {object_path} → {e.code} {body[:200]}")
        return self.public_url(object_path)


def enrich_images(entries, manifest, uploader, stats, dry_run):
    """image_url 이 비고 정리된 JPEG 가 있으면 Storage 에 올려 image_url 을 채운다 (entries 변형).
    반환: 로컬 product_barcodes 에 되쓸 [(barcode, image_url), ...]."""
    writeback = []
    for e in entries:
        if e.get("image_url"):
            continue
        man = manifest.get(e["barcode"])
        if not man or not os.path.exists(man.get("local_path", "")):
            stats["image_no_local"] += 1
            continue
        if dry_run:
            stats["image_would_upload"] += 1
            continue
        if not uploader.enabled:
            stats["image_skipped_no_creds"] += 1
            continue
        try:
            with open(man["local_path"], "rb") as fh:
                data = fh.read()
            e["image_url"] = uploader.upload_bytes(data, image_object_path(e["barcode"], data))
            if not e.get("image_source_url"):
                e["image_source_url"] = man.get("source_url")
            writeback.append((e["barcode"], e["image_url"]))
            stats["image_uploaded"] += 1
        except Exception as ex:  # noqa: BLE001 — 한 건 실패가 전체 업로드를 막지 않게
            print(f"  IMG FAIL {e['barcode']}: {ex}")
            stats["image_failed"] += 1
    return writeback


def writeback_attachments(cur, attach_rows):
    """붙은 행에만 prod_master_id 기록하고 실제로 쓴 행 수를 돌려준다.
    행 식별자(id) 기준이라 같은 barcode를 가진 다른 promoted 행(conflict/held)은 건드리지 않는다.
    업로드가 읽은 승격 세대(promoted_at)와 바코드가 지금도 같을 때만 쓴다 — 업로드 도중 행이
    취소·수정·재승격됐으면 옛 응답이 새 세대를 채우지 않는다. promoted_at 이 없는 옛 승격 행은
    NULL 끼리 같은 세대로 본다(is not distinct from).
    attach_rows: [(prod_master_id, collected_id, local_master_id, promoted_at, barcode), ...]"""
    written = 0
    for prod_id, cid, local_id, promoted_at, barcode in attach_rows:
        cur.execute("""update collected_products set prod_master_id=%s
                       where id=%s and promoted_master_id=%s and stage='promoted'
                         and promoted_at is not distinct from %s and barcode=%s""",
                    (prod_id, cid, local_id, promoted_at, barcode))
        written += cur.rowcount
    return written


ATTACHED_RESULTS = ("inserted", "existing", "exists")
# RPC 0021 이 돌려주는 master 결과 전부. 이 밖(예: 0020 의 updated)이면 운영 RPC 가 0021 이 아니다.
RPC_MASTER_STATUSES = ("inserted", "existing", "review_held", "verified_held", "renamed_held", "empty_held")


def local_has_upload_receipts(src) -> bool:
    """LOCAL(원본)에 upload_receipts 테이블이 있는지(읽기만)."""
    with src.cursor() as cur:
        cur.execute("select to_regclass('public.upload_receipts') is not null")
        return cur.fetchone()[0]


def receipt_rows(local_id, entries, res):
    """RPC 결과 → 영수증 행 목록(순수 함수). entries 는 fetch_promoted 의 그 master 바코드 항목.
    바코드 결과: master inserted+바코드 inserted → inserted, master existing+바코드 inserted → existing,
    exists → exists, conflict → conflict, 결과 목록에 없으면 master 결과(보류 사유).
    prod_master_id 는 붙은 경우(inserted·existing·exists)에만 채운다."""
    bc_status = {}
    for b in res.get("barcodes") or []:
        bc_status.setdefault(b["barcode"], b["status"])  # 같은 바코드 중복 입력이면 첫 결과
    m_status, m_id = res["master_status"], res.get("master_id")
    out = []
    for e in entries:
        s = bc_status.get(e["barcode"])
        if s == "inserted":
            result = "existing" if m_status == "existing" else "inserted"
        elif s in ("exists", "conflict"):
            result = s
        else:
            result = m_status
        out.append({"collected_id": e["collected_id"], "local_master_id": local_id,
                    "barcode": e["barcode"], "promoted_at": e["promoted_at"], "result": result,
                    "prod_master_id": m_id if result in ATTACHED_RESULTS and m_id else None})
    return out


def insert_receipts(cur, run_id, rows, error=None):
    for r in rows:
        cur.execute("""insert into upload_receipts
                         (run_id, collected_id, local_master_id, barcode, promoted_at, result,
                          prod_master_id, error)
                       values (%s, %s, %s, %s, %s, %s, %s, %s)""",
                    (run_id, r["collected_id"], r["local_master_id"], r["barcode"], r["promoted_at"],
                     r["result"], r["prod_master_id"], error))


def classify_dryrun(target, vals, barcodes):
    """쓰기 없이 master/barcode가 어떻게 처리될지 분류 (운영 읽기만). RPC와 동일 분류."""
    owners = target.barcode_owner_masters([bc["barcode"] for bc in barcodes])
    renamed = renamed_owner_id(owners, vals)
    existing_id, vstatus = target.plan_master(vals)
    if renamed is not None:
        held_id, held_status = renamed, "renamed_held"
    elif vstatus == "verified":
        held_id, held_status = existing_id, "verified_held"
    elif vstatus == "needs_review":
        held_id, held_status = existing_id, "review_held"
    else:
        held_id = held_status = None
    if held_status:
        # 보류: 새 연결 없이, 입력 바코드 중 이미 그 master 소속인 것만 exists (RPC 0021 과 동일)
        kept = [{"barcode": bc["barcode"], "status": "exists"} for bc in barcodes
                if str(target.barcode_owner(bc["barcode"])) == str(held_id)]
        return {"master_id": held_id, "master_status": held_status, "barcodes": kept}
    m_status = "existing" if existing_id is not None else "inserted"
    bc_out, attached = [], 0
    attached_here = set()  # 이 호출에서 이미 붙인 바코드 — RPC 는 같은 바코드 재입력을 exists 로 본다
    for bc in barcodes:
        owner = target.barcode_owner(bc["barcode"])
        if bc["barcode"] in attached_here:
            s = "exists"; attached += 1
        elif owner is None:
            s = "inserted"; attached += 1; attached_here.add(bc["barcode"])
        elif existing_id is not None and str(owner) == str(existing_id):
            s = "exists"; attached += 1
        else:
            s = "conflict"
        bc_out.append({"barcode": bc["barcode"], "status": s})
    # 신규 master인데 붙을 barcode가 없으면 빈 master → 정리 대상(empty_held)
    if m_status == "inserted" and attached == 0:
        return {"master_id": None, "master_status": "empty_held", "barcodes": bc_out}
    return {"master_id": existing_id, "master_status": m_status, "barcodes": bc_out}


def run_upload(src, target, *, ids=None, all_=False, dry_run=False, manifest=None,
               uploader=None, run_id=None):
    """승격분을 운영에 올리고 집계(Counter)를 돌려준다.

    master 하나의 RPC 가 끝나면 바로 LOCAL 트랜잭션 하나로 영수증·연결 기록(prod_master_id)·
    Storage image_url 반영을 커밋한다 — 중간에 멈춰도 운영에 반영된 master 의 기록이 남는다.
    RPC 가 실패하면 그 master 의 바코드마다 error 영수증을 커밋하고 다음 master 로 넘어간다.
    dry-run 은 영수증·기록을 쓰지 않는다."""
    stats = Counter()
    if run_id is None:
        run_id = datetime.now().strftime("%Y%m%dT%H%M%S.%f")
    if manifest is None:
        manifest = load_image_manifest()
    if uploader is None:
        uploader = StorageUploader()
    if not dry_run and not local_has_upload_receipts(src):
        raise SystemExit("LOCAL에 upload_receipts가 없습니다 — pipeline/sql/upload_receipts.sql 먼저 적용")

    masters, bc_by_master, skipped = fetch_promoted(src, ids=ids, all_=all_)
    stats["skipped_ids"] = len(skipped)
    if skipped:
        print(f"건너뜀(승격 아님/없음) {len(skipped)}건: {', '.join(skipped[:5])}"
              + (" ..." if len(skipped) > 5 else ""))
    if not masters:
        print("업로드할 승격분 없음")
        return stats
    print(f"승격 master {len(masters)} / barcode {sum(len(v) for v in bc_by_master.values())}"
          + (" [DRY-RUN]" if dry_run else f" [run_id {run_id}]"))
    # prod_master_id는 collected_products(행=바코드) 단위로, **실제로 운영에 붙은
    # 바코드(inserted/existing/exists) 행에만** 기록한다. 보류·conflict 행은 운영에 올라가지
    # 않았으므로 기록하지 않는다(=미매핑, 영수증에 사유가 남는다).
    for local_id, vals in masters.items():
        entries = bc_by_master.get(local_id, [])
        # image_url 이 비어있는 바코드는 정리된 JPEG 를 Storage 에 올려 채운다.
        image_writeback = enrich_images(entries, manifest, uploader, stats, dry_run)
        payload = [{k: e[k] for k in ("barcode", "size", "image_url", "image_source_url")}
                   for e in entries]
        if dry_run:
            res = classify_dryrun(target, vals, payload)
        else:
            try:
                res = target.upload(vals, payload)
            except Exception as ex:  # noqa: BLE001 — 한 master 실패가 다음 master 를 막지 않게
                msg = str(ex)[:500]
                print(f"  ERROR ({vals['brand']} / {vals['name']}) — {msg.splitlines()[0] if msg else ''}")
                stats["master_error"] += 1
                err_rows = [{"collected_id": e["collected_id"], "local_master_id": local_id,
                             "barcode": e["barcode"], "promoted_at": e["promoted_at"],
                             "result": "error", "prod_master_id": None} for e in entries]
                with src.cursor() as cur:
                    insert_receipts(cur, run_id, err_rows, error=msg)
                src.commit()
                continue
            if res.get("master_status") not in RPC_MASTER_STATUSES:
                # 0020 이 아직 운영에 있으면 updated 등이 온다 — 이 master 의 LOCAL 기록을 쓰기 전에 멈춘다.
                raise SystemExit(f"운영 RPC가 0021이 아닙니다 (master_status={res.get('master_status')!r},"
                                 f" {vals['brand']} / {vals['name']}) — 운영에 0021 을 먼저 적용."
                                 " 이 master 는 운영에 반영됐을 수 있으나 LOCAL 기록은 남기지 않았습니다")
        stats[f"master_{res['master_status']}"] += 1
        if res["master_status"] == "verified_held":
            print(f"  HOLD verified master ({vals['brand']} / {vals['name']}) — barcode 보류")
        elif res["master_status"] == "review_held":
            print(f"  REVIEW-HELD ({vals['brand']} / {vals['name']}) — 운영 master 검토 필요 상태, barcode 보류")
        elif res["master_status"] == "renamed_held":
            print(f"  RENAMED-HELD ({vals['brand']} / {vals['name']}) — 운영에서 이름이 바뀐 같은 상품, 수동 확인")
        elif res["master_status"] == "empty_held":
            print(f"  EMPTY-HELD ({vals['brand']} / {vals['name']}) — 바코드 전부 충돌, master 미생성")
        for b in res["barcodes"]:
            stats[f"barcode_{b['status']}"] += 1
            if b["status"] == "conflict":
                print(f"  CONFLICT barcode {b['barcode']} — 운영에서 다른 master 소속, 보류")
        if dry_run:
            continue

        rows = receipt_rows(local_id, entries, res)
        attach = [(r["prod_master_id"], r["collected_id"], local_id, r["promoted_at"], r["barcode"])
                  for r in rows if r["prod_master_id"]]
        with src.cursor() as cur:
            insert_receipts(cur, run_id, rows)
            written = writeback_attachments(cur, attach)
            # Storage 업로드 성공분의 image_url 을 로컬에도 반영 (재실행 시 재업로드 회피).
            # 운영이 그 URL 을 실제로 받은 경우(바코드 결과 inserted)만 — 보류·exists 는 운영 값이 따로 있다.
            took_url = {b["barcode"] for b in res["barcodes"] if b["status"] == "inserted"}
            for barcode, image_url in image_writeback:
                if barcode not in took_url:
                    continue
                cur.execute("update product_barcodes set image_url=%s where barcode=%s",
                            (image_url, barcode))
        src.commit()
        stats["attached_written"] += written
        if written < len(attach):
            # 업로드 도중 그 행이 취소·수정·재승격돼 새 세대가 됨 — 옛 응답으로 채우지 않는다.
            stats["stale_writeback"] += len(attach) - written
            print(f"  STALE ({vals['brand']} / {vals['name']}) — 업로드 중 승격 세대가 바뀐 행"
                  f" {len(attach) - written}건 기록 안 함")
    return stats


def _uuid_list(text):
    out = []
    for part in text.split(","):
        part = part.strip()
        if part:
            try:
                out.append(str(uuid.UUID(part)))
            except ValueError:
                raise argparse.ArgumentTypeError(f"uuid 형식이 아님: {part}")
    if not out:
        raise argparse.ArgumentTypeError("--ids 에 uuid 가 하나도 없음")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target-dsn", default=None)
    ap.add_argument("--dry-run", action="store_true")
    grp = ap.add_mutually_exclusive_group()
    grp.add_argument("--ids", type=_uuid_list, default=None,
                     help="콤마 구분 collected_products.id — 그 행의 승격 master 만 업로드")
    grp.add_argument("--all", dest="all_", action="store_true",
                     help="이미 연결된 master 포함 모든 승격 master 업로드 (기본: 미연결 master 만)")
    args = ap.parse_args()

    target = PgTarget(args.target_dsn) if args.target_dsn else RestTarget()
    manifest = load_image_manifest()
    uploader = StorageUploader()

    with connect() as src:
        stats = run_upload(src, target, ids=args.ids, all_=args.all_, dry_run=args.dry_run,
                           manifest=manifest, uploader=uploader)
    print(dict(stats))


if __name__ == "__main__":
    main()
