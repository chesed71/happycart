/// 2a 검토완료 매니페스트의 승인 alias 를 앱 카탈로그 진실원에 반영하는 importer.
///
/// Task 4(이 파일): 검증 로직 — 스냅샷 해시·membership·정규화 drift·신규 유일성·과매칭.
/// Task 5: appendApproved·재생성·자체 게이트·실패 원복·CLI(main).
///
/// 앱 정규화 정본(normalizeIngredientToken)을 패키지에서 직접 재사용해 drift 를 차단한다.
/// SHA-256 은 crypto 패키지 대신 shasum 서브프로세스로 계산(패키지 런타임 의존성 0 유지).
library;

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
