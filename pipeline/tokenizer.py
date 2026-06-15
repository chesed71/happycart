"""원재료 원문 → ingredients_tokens 규칙 기반 토크나이저.

기존 시드의 수작업 토큰화 규칙을 재현한다 (golden test: tokenize_ingredients.py --golden):
  - 최상위는 쉼표·문장점(. + 공백) 구분, 괄호 안은 하위 성분으로 전개해 부모 뒤에 붙인다
  - 원산지 표기 괄호("밀:미국산,호주산", "말레이시아산", "외국산:덴마크,프랑스")는 버린다
    · 원산지 판정은 국가/지역명 화이트리스트 기반 — '구연산'처럼 '산'으로 끝나는
      성분명을 오인하지 않는다
  - 성분명 앞의 원산지어는 벗긴다 ("말레이시아산 팜유" → "팜유")
  - 섹션 라벨("*면:", "*스프류:", "성분함량:")은 벗긴다
  - 함량(67%, 20g 이상)·수량(4종)·로마숫자 첨자(밀가루Ⅰ)는 제거한다.
    단 이름 끝의 일반 숫자는 유지한다 ("조미양념2")
  - 영양 표기성 토큰(한글 없음 + 숫자, "100g당" 등 단위 포함)은 버린다
  - 중복 토큰은 첫 등장만 유지 (순서 보존)
  - '혼합제제/혼합제재'처럼 내용물이 전부 전개되는 포장 명칭은 토큰에 넣지 않는다

참고: docs/superpowers/specs/2026-06-11-local-db-data-ingestion-plan.md §4.4
"""
from __future__ import annotations

import re

# 내용물을 전개하고 자신은 토큰으로 남기지 않는 포장 명칭
DROP_PARENTS = {"혼합제제", "혼합제재"}

# 토큰으로 남기지 않는 메타 단어
DROP_TOKENS = {"수분제외", "성분함량", "고형분", "이상", "미만", "함유"}

# 원산지 국가/지역명 (어간 — '산'/'등' 접미는 벗겨서 비교)
ORIGIN_STEMS = {
    "국", "외국", "수입", "미국", "호주", "중국", "일본", "말레이시아", "인도네시아",
    "태국", "베트남", "필리핀", "칠레", "스페인", "프랑스", "독일", "덴마크", "이탈리아",
    "이태리", "캐나다", "러시아", "브라질", "아르헨티나", "뉴질랜드", "페루", "노르웨이",
    "영국", "인도", "터키", "멕시코", "폴란드", "네덜란드", "벨기에", "스위스",
    "오스트리아", "스웨덴", "핀란드", "그리스", "포르투갈", "헝가리", "체코",
    "우크라이나", "모로코", "이집트", "에콰도르", "콜롬비아", "파라과이", "우루과이",
    "싱가포르", "대만", "홍콩", "캄보디아", "라오스", "미얀마", "스리랑카", "파키스탄",
}

_PERCENT = re.compile(r"\d[\d,\.]*\s*%")
_UNIT_AMOUNT = re.compile(r"\d[\d,\.]*\s*(mg|kg|g|ml|mL|L|kcal)(당)?(\s*(이상|미만))?", re.IGNORECASE)
_TRAILING_COUNT = re.compile(r"\d+종$")
_ROMAN = re.compile(r"[ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩ]+$")
_LABEL = re.compile(r"^[\*\s]*[가-힣A-Za-z0-9]{1,8}\s*:\s*")
_KOREAN = re.compile(r"[가-힣]")
_DIGIT = re.compile(r"\d")
_FULLWIDTH = str.maketrans({"（": "(", "）": ")", "［": "[", "］": "]", "｛": "{", "｝": "}"})
_OPEN = {"(": ")", "[": "]", "{": "}"}
_CLOSE = {")": "(", "]": "[", "}": "{"}


def _is_origin_word(w: str) -> bool:
    w = w.strip().removesuffix("등").strip()
    w = w.removesuffix("산")
    return w in ORIGIN_STEMS


def _split_top(s: str) -> list[str]:
    """괄호 깊이 0에서 쉼표·슬래시·문장점(. 뒤 공백/끝)으로 분할."""
    out, buf, depth = [], [], 0
    for i, ch in enumerate(s):
        if ch in _OPEN:
            depth += 1
        elif ch in _CLOSE:
            depth = max(0, depth - 1)
        is_sep = depth == 0 and (
            ch in ",/" or (ch == "." and (i + 1 == len(s) or s[i + 1].isspace()))
        )
        if is_sep:
            out.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
    out.append("".join(buf))
    return [p.strip() for p in out if p.strip()]


def _clean_name(name: str) -> str:
    name = _LABEL.sub("", name)
    name = _PERCENT.sub("", name)
    name = _UNIT_AMOUNT.sub("", name)
    name = _TRAILING_COUNT.sub("", name.strip())
    name = _ROMAN.sub("", name.strip())
    name = name.strip(" .·-*")
    # 선행 원산지어 제거: "말레이시아산 팜유" → "팜유"
    words = name.split()
    while len(words) > 1 and _is_origin_word(words[0]):
        words = words[1:]
    name = " ".join(words)
    # 후행 메타 단어 제거: "... 이상"
    words = name.split()
    while words and words[-1] in DROP_TOKENS:
        words = words[:-1]
    return " ".join(words)


def _is_origin_group(content: str) -> bool:
    """괄호 내용 전체가 원산지 표기인지.

    "밀:미국산,호주산" (성분:원산지), "말레이시아산", "외국산:덴마크,프랑스,독일 등"
    """
    pieces = [p.strip() for p in re.split(r"[,/]", content) if p.strip()]
    if not pieces:
        return True
    for p in pieces:
        if ":" in p:
            left, right = (x.strip() for x in p.split(":", 1))
            # "성분:원산지" 또는 "외국산:국가" — 어느 한쪽이 원산지어면 통과
            if _is_origin_word(right) or _is_origin_word(left):
                continue
            return False
        p = _PERCENT.sub("", p).strip()
        if not _is_origin_word(p):
            return False
    return True


def _extract_parens(item: str) -> tuple[str, list[str]]:
    """이름과 괄호 그룹들을 분리. 중첩 괄호는 바깥 그룹 하나로 묶인다."""
    name_parts, groups, buf, depth = [], [], [], 0
    for ch in item:
        if ch in _OPEN:
            if depth == 0:
                buf = []
            else:
                buf.append(ch)
            depth += 1
        elif ch in _CLOSE:
            depth -= 1
            if depth == 0:
                groups.append("".join(buf))
            else:
                buf.append(ch)
        elif depth > 0:
            buf.append(ch)
        else:
            name_parts.append(ch)
    return "".join(name_parts), groups


def _drop_token(token: str) -> bool:
    if not token or token in DROP_TOKENS or token in DROP_PARENTS:
        return True
    if _is_origin_word(token):
        return True
    if not _KOREAN.search(token):
        # 한글이 전혀 없는 토큰: 숫자가 섞였거나 너무 짧으면 영양 표기/단위로 본다
        if _DIGIT.search(token) or len(token) < 3:
            return True
    return False


def _tokenize_fragment(fragment: str, out: list[str]) -> None:
    for item in _split_top(fragment):
        # "미국산: 감자, 산도조절제" — 원산지 라벨 뒤가 성분 목록인 경우
        m = _LABEL.match(item)
        if m and _is_origin_word(m.group(0).strip(" *:")):
            item = item[m.end():]
        name, groups = _extract_parens(item)
        name = _clean_name(name)
        sub_groups = [g for g in groups if not _is_origin_group(g)]
        if not _drop_token(name):
            _push(out, name)
        for g in sub_groups:
            _tokenize_fragment(g, out)


def _push(out: list[str], token: str) -> None:
    if token and token not in out:
        out.append(token)


def tokenize(raw: str) -> list[str]:
    if not raw or not raw.strip():
        return []
    s = raw.translate(_FULLWIDTH)
    out: list[str] = []
    _tokenize_fragment(s, out)
    return out
