/// 전체 성분표(라벨 원문) 표시용 순수 helper.
///
/// `product_masters.ingredients_raw`(라벨 원문 문자열)를 사람이 읽는 조각으로
/// 분리하고, 각 조각을 룰 패키지 [rules.computeVerdict] 로 bad/good 분류한다.
/// 강조 대상은 **서버가 이미 판정한** bad/good canonical key 집합에 한정해,
/// 룰 버전 스큐로 화면 판정과 성분표 강조가 어긋나지 않게 한다.
library;

import 'package:happycart_rules/happycart_rules.dart' as rules;

/// 성분 한 조각의 강조 구분.
enum IngredientMark { bad, good, neutral }

/// 전체 성분표의 한 행.
class IngredientTableEntry {
  /// 표시용 원문 조각(트림된 상태). 예: `밀가루(밀:미국산,호주산)`.
  final String text;

  /// bad/good/중립 구분.
  final IngredientMark mark;

  /// bad/good 일 때 매칭된 canonical key(라벨 조회용). 중립이면 `null`.
  final String? canonicalKey;

  const IngredientTableEntry({
    required this.text,
    required this.mark,
    this.canonicalKey,
  });
}

/// [raw] 를 최상위 쉼표 기준으로 분리한 뒤 각 조각을 분류한다.
///
/// - 괄호/대괄호 안의 쉼표는 하위 원재료 표기이므로 분리하지 않는다
///   (예: `밀가루(밀:미국산,호주산)` 는 한 조각).
/// - 분류는 [rules.computeVerdict] 를 조각 단위로 재사용하되, 매칭 canonical
///   key 가 [badKeys]/[goodKeys] 에 포함될 때만 강조한다.
List<IngredientTableEntry> buildIngredientTable(
  String raw, {
  required List<String> badKeys,
  required List<String> goodKeys,
}) {
  final badSet = badKeys.toSet();
  final goodSet = goodKeys.toSet();

  final entries = <IngredientTableEntry>[];
  for (final piece in _splitTopLevel(raw)) {
    final text = piece.trim();
    if (text.isEmpty) continue;

    var mark = IngredientMark.neutral;
    String? key;
    try {
      final result = rules.computeVerdict(
        rules.IngredientInput(tokens: [text]),
      );
      final bad = result.badMatches
          .where((m) => badSet.contains(m.canonicalKey))
          .toList();
      final good = result.goodMatches
          .where((m) => goodSet.contains(m.canonicalKey))
          .toList();
      if (bad.isNotEmpty) {
        mark = IngredientMark.bad;
        key = bad.first.canonicalKey;
      } else if (good.isNotEmpty) {
        mark = IngredientMark.good;
        key = good.first.canonicalKey;
      }
    } on ArgumentError {
      // 정규화 후 유효 토큰이 없는 조각(구두점 등) → 중립으로 둔다.
    }

    entries.add(IngredientTableEntry(text: text, mark: mark, canonicalKey: key));
  }
  return entries;
}

/// 괄호 깊이를 추적해 최상위(깊이 0) 쉼표에서만 분리한다.
List<String> _splitTopLevel(String raw) {
  final result = <String>[];
  final buffer = StringBuffer();
  var depth = 0;
  for (final rune in raw.runes) {
    final ch = String.fromCharCode(rune);
    if (ch == '(' || ch == '[') {
      depth++;
    } else if (ch == ')' || ch == ']') {
      if (depth > 0) depth--;
    }
    if (ch == ',' && depth == 0) {
      result.add(buffer.toString());
      buffer.clear();
      continue;
    }
    buffer.write(ch);
  }
  if (buffer.isNotEmpty) result.add(buffer.toString());
  // 닫히지 않은 괄호가 있으면(malformed raw) 그 지점부터 이후 쉼표가 마지막 한
  // 조각에 흡수된다. 억지로 재분리하면 그 안의 정상 괄호 그룹까지 깨질 수 있어,
  // best-effort 결과를 그대로 둔다 — 정상 조각은 항상 보존하고 안 닫힌 뒷부분만
  // 원문 그대로 한 조각으로 노출한다.
  return result;
}
