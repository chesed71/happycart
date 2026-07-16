/// 2a 검토완료 매니페스트의 승인 alias 를 앱 카탈로그 진실원에 반영하는 importer.
///
/// Task 4(이 파일): 검증 로직 — 스냅샷 해시·membership·정규화 drift·신규 유일성·과매칭.
/// Task 5: appendApproved·재생성·자체 게이트·실패 원복·CLI(main).
///
/// 앱 정규화 정본(normalizeIngredientToken)을 패키지에서 직접 재사용해 drift 를 차단한다.
/// SHA-256 은 crypto 패키지 대신 shasum 서브프로세스로 계산(패키지 런타임 의존성 0 유지).
library;

import 'dart:convert';
import 'dart:io';

import 'package:happycart_rules/happycart_rules.dart';

/// 카탈로그 파일 raw bytes 의 SHA-256 (lowercase hex).
String sha256OfFile(String path) {
  final res = Process.runSync('shasum', ['-a', '256', path]);
  if (res.exitCode != 0) {
    throw StateError('shasum 실패($path): ${res.stderr}');
  }
  return (res.stdout as String).trim().split(RegExp(r'\s+')).first.toLowerCase();
}

/// 카탈로그 bad+good 전체 엔트리.
List<Map<String, dynamic>> allEntries(Map<String, dynamic> catalog) => [
      ...(catalog['bad'] as List).cast<Map<String, dynamic>>(),
      ...(catalog['good'] as List).cast<Map<String, dynamic>>(),
    ];

bool _isENumber(String norm) => RegExp(r'^e\d+$').hasMatch(norm);

/// alias(패턴)가 tokenLike(다른 alias/토큰)를 매칭 규칙상 커버하는가.
/// verdict.dart `_findFirstMatch` 와 동일: 정규화 후 E-number 는 정확 일치, 그 외는 substring 포함.
bool covers(String alias, String tokenLike) {
  final na = normalizeIngredientToken(alias);
  if (na.isEmpty) return false;
  final nt = normalizeIngredientToken(tokenLike);
  return _isENumber(na) ? nt == na : nt.contains(na);
}

/// 매니페스트 `catalogContentSha256` 가 현재 카탈로그 파일 해시와 일치하는지.
/// 불일치 = 대조 이후 카탈로그가 바뀜(version bump 없는 변경 포함). reject.
List<String> verifySnapshot(Map<String, dynamic> manifest, String catalogFilePath) {
  final expected = (manifest['catalogContentSha256'] as String).toLowerCase();
  final actual = sha256OfFile(catalogFilePath);
  if (actual != expected) {
    return ['스냅샷 해시 불일치: 카탈로그 $actual != 매니페스트 $expected'];
  }
  return [];
}

/// 각 승인 후보 canonicalKey 가 카탈로그에 실존하는지.
List<String> verifyMembership(
    List<Map<String, dynamic>> approved, Map<String, dynamic> catalog) {
  final keys = {for (final e in allEntries(catalog)) e['canonicalKey'] as String};
  final errors = <String>[];
  for (final c in approved) {
    final k = c['canonicalKey'] as String;
    if (!keys.contains(k)) {
      errors.add("membership 위반: canonicalKey '$k' 카탈로그에 없음");
    }
  }
  return errors;
}

/// 앱 정규화를 재적용해 매니페스트 normalizedPreview 와 일치하는지(정규화 drift 방지).
List<String> verifyNormalizedPreview(List<Map<String, dynamic>> approved) {
  final errors = <String>[];
  for (final c in approved) {
    final proposed = c['proposedAlias'] as String;
    final preview = c['normalizedPreview'] as String;
    final recomputed = normalizeIngredientToken(proposed);
    if (recomputed != preview) {
      errors.add("정규화 drift: '$proposed' → '$recomputed' != preview '$preview'");
    }
  }
  return errors;
}

/// 각 신규 alias 의 정규화형이 기존 카탈로그 전체·다른 신규 후보와 충돌하지 않는지.
/// 검사 대상은 신규분만 — 기존 내부 공백변형 중복(19쌍)은 무해하므로 관용한다.
List<String> verifyNewUniqueness(
    List<Map<String, dynamic>> approved, Map<String, dynamic> catalog) {
  final existingNorms = <String>{
    for (final e in allEntries(catalog))
      for (final a in (e['aliases'] as List).cast<String>())
        normalizeIngredientToken(a),
  };
  final errors = <String>[];
  final seen = <String, String>{}; // 정규화형 -> proposedAlias
  for (final c in approved) {
    final proposed = c['proposedAlias'] as String;
    final n = normalizeIngredientToken(proposed);
    if (existingNorms.contains(n)) {
      errors.add(
          "신규 유일성 위반: '$proposed' 정규화형 '$n' 이 기존 카탈로그 alias 와 충돌 (key ${c['canonicalKey']})");
    }
    if (seen.containsKey(n)) {
      errors.add("신규 유일성 위반: '$proposed' 가 다른 신규 후보 '${seen[n]}' 와 정규화 충돌");
    }
    seen[n] = proposed;
  }
  return errors;
}

/// 신규 alias 가 다른 canonicalKey 의 alias(기존+신규)를 매칭 규칙상 커버하는지.
/// 정규화 유일성만으로는 다른 키를 shadow 하는 alias 를 못 잡으므로 별도 검사(2a preflight 승계).
List<String> verifyNoOvermatch(
    List<Map<String, dynamic>> approved, Map<String, dynamic> catalog) {
  final pairs = <MapEntry<String, String>>[]; // canonicalKey -> alias
  for (final e in allEntries(catalog)) {
    final k = e['canonicalKey'] as String;
    for (final a in (e['aliases'] as List).cast<String>()) {
      pairs.add(MapEntry(k, a));
    }
  }
  for (final c in approved) {
    pairs.add(MapEntry(c['canonicalKey'] as String, c['proposedAlias'] as String));
  }
  final errors = <String>[];
  for (final c in approved) {
    final k = c['canonicalKey'] as String;
    final newAlias = c['proposedAlias'] as String;
    for (final p in pairs) {
      if (p.key == k) continue; // 같은 키는 과매칭 아님(내부 중복)
      if (covers(newAlias, p.value)) {
        errors.add(
            "과매칭: 신규 alias '$newAlias'(key $k)가 다른 키 '${p.key}'의 alias '${p.value}' 를 커버");
      }
    }
  }
  return errors;
}

/// 승인 후보의 proposedAlias 원문을 해당 canonicalKey 엔트리 aliases 뒤에 안정 append.
/// 원본 카탈로그는 불변(깊은 복사). 이미 존재하는 alias 는 중복 추가하지 않는다(멱등).
/// normalizedPreview 는 절대 반영하지 않는다.
Map<String, dynamic> appendApproved(
    Map<String, dynamic> catalog, List<Map<String, dynamic>> approved) {
  // JSON 왕복으로 깊은 복사 — 키 순서 보존, 원본 미변경.
  final copy = jsonDecode(jsonEncode(catalog)) as Map<String, dynamic>;

  Map? findEntry(String key) {
    for (final section in const ['bad', 'good']) {
      for (final e in (copy[section] as List)) {
        if ((e as Map)['canonicalKey'] == key) return e;
      }
    }
    return null;
  }

  for (final c in approved) {
    final entry = findEntry(c['canonicalKey'] as String);
    if (entry == null) continue; // membership 는 사전 검증됨
    final alias = c['proposedAlias'] as String; // 원문 append
    final aliases = entry['aliases'] as List;
    if (!aliases.contains(alias)) aliases.add(alias);
  }
  return copy;
}

// ── CLI (Task 5) ──────────────────────────────────────────────────────────

const _catalogDefault = 'data/ingredient_catalog.json';

/// 카탈로그 변경으로 재생성되는 파생 파일 — 멱등 비교·원복 대상.
/// alias append 시 golden 스냅샷도 재덤프해야 golden roundtrip 테스트가 통과한다.
const _regeneratedFiles = [
  'lib/src/bad_ingredients.g.dart',
  'lib/src/good_ingredients.g.dart',
  'test/golden/catalog_snapshot.json',
];

Map<String, String> _parseArgs(List<String> args) {
  final out = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--manifest' && i + 1 < args.length) {
      out['manifest'] = args[++i];
    } else if (a == '--catalog' && i + 1 < args.length) {
      out['catalog'] = args[++i];
    } else {
      stderr.writeln('알 수 없는 인자: $a');
      exit(2);
    }
  }
  if (!out.containsKey('manifest')) {
    stderr.writeln(
        '사용: dart run tool/import_aliases.dart --manifest <매니페스트> [--catalog <카탈로그>]');
    exit(2);
  }
  return out;
}

/// 원복이 사용자의 다른 변경을 삼키지 않도록, 대상 파일이 clean 인지 확인(§11 가드).
void _requireClean(List<String> targets) {
  final res = Process.runSync('git', ['status', '--porcelain', '--', ...targets]);
  final dirty = (res.stdout as String).trim();
  if (dirty.isNotEmpty) {
    stderr.writeln('대상 파일이 clean 하지 않습니다(원복 안전 위반). 커밋/원복 후 재실행:\n$dirty');
    exit(1);
  }
}

/// 카탈로그 JSON 을 dump_catalog_snapshot 과 동일 규칙으로 재기록(2-space indent + 말미 개행).
void _writeCatalog(String path, Map<String, dynamic> catalog) {
  const encoder = JsonEncoder.withIndent('  ');
  File(path).writeAsStringSync('${encoder.convert(catalog)}\n');
}

void _run(String label, String cmd, List<String> args) {
  final res = Process.runSync(cmd, args);
  if (res.exitCode != 0) {
    throw StateError('$label 실패(exit ${res.exitCode}):\n${res.stdout}\n${res.stderr}');
  }
}

/// generate_catalog(.g.dart) + dump_catalog_snapshot(golden) 재생성. 파생 파일 내용 반환.
Map<String, String> _regenerateAll() {
  _run('generate_catalog', 'dart', ['run', 'tool/generate_catalog.dart']);
  _run('dump_golden', 'dart', ['run', 'tool/dump_catalog_snapshot.dart', '--force']);
  return {for (final f in _regeneratedFiles) f: File(f).readAsStringSync()};
}

/// 자체 게이트: 재생성 멱등(2회 동일) + dart analyze + dart test.
/// verify_catalog.sh 는 커밋 전 freshness(git diff)로 실패하므로 여기선 쓰지 않는다.
void _selfGate() {
  final first = _regenerateAll();
  final second = _regenerateAll();
  for (final f in _regeneratedFiles) {
    if (first[f] != second[f]) {
      throw StateError('재생성 비멱등: $f 두 번 생성 결과 상이');
    }
  }
  _run('dart analyze', 'dart', ['analyze']);
  _run('dart test', 'dart', ['test']);
}

void _gitRestore(List<String> targets) {
  Process.runSync('git', ['checkout', '--', ...targets]);
}

void main(List<String> args) {
  final opts = _parseArgs(args);
  final manifestPath = opts['manifest']!;
  final catalogPath = opts['catalog'] ?? _catalogDefault;
  final touched = [catalogPath, ..._regeneratedFiles];

  _requireClean(touched);

  final manifest =
      jsonDecode(File(manifestPath).readAsStringSync()) as Map<String, dynamic>;
  final catalog =
      jsonDecode(File(catalogPath).readAsStringSync()) as Map<String, dynamic>;
  final approved = (manifest['candidates'] as List)
      .cast<Map<String, dynamic>>()
      .where((c) => c['reviewerStatus'] == '승인')
      .toList();

  // 검증 5종 — verifySnapshot 최우선(재실행은 해시 게이트에서 reject 되는 것이 의도).
  final errors = <String>[
    ...verifySnapshot(manifest, catalogPath),
    ...verifyMembership(approved, catalog),
    ...verifyNormalizedPreview(approved),
    ...verifyNewUniqueness(approved, catalog),
    ...verifyNoOvermatch(approved, catalog),
  ];
  if (errors.isNotEmpty) {
    stderr.writeln('검증 실패(${errors.length}건) — 반영 중단:');
    for (final e in errors) {
      stderr.writeln('  - $e');
    }
    exit(1); // 반영 전이라 원복 불필요
  }

  // append(원문) + 원자적 재기록.
  _writeCatalog(catalogPath, appendApproved(catalog, approved));

  // 재생성 + 자체 게이트. 어느 단계든 실패하면 파생 파일까지 git 원복(부분 반영 금지).
  try {
    _selfGate();
  } catch (e) {
    stderr.writeln('반영 게이트 실패 → git 원복:\n$e');
    _gitRestore(touched);
    exit(1);
  }

  stdout.writeln('반영 완료: 승인 ${approved.length}건 append, 재생성·자체게이트 통과.');
  stdout.writeln('주의: 이 카탈로그 변경은 오탐0 게이트(Task 7) 통과 후 커밋하세요.');
}
