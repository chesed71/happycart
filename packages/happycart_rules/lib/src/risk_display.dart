/// not_okay 화면의 성분별 건강 위험도 표시용 순수 helper.
///
/// 판정(okay/notOkay) 로직에는 관여하지 않는다 — 이미 not_okay 로 판정된
/// 성분 목록을 위험도 순으로 정렬해 UI 에 넘기기 위한 표시 모델만 만든다.
library;

import 'bad_ingredients.dart';

/// 성분 하나의 위험도 표시 모델(불변).
class IngredientRiskDisplay {
  final String canonicalKey;
  final String reasonCode;
  final RiskLevel? riskLevel;
  final String? riskReason;
  final String? riskEvidence;

  const IngredientRiskDisplay({
    required this.canonicalKey,
    required this.reasonCode,
    required this.riskLevel,
    required this.riskReason,
    required this.riskEvidence,
  });
}

/// [detectedKeys] 를 [catalog] 에서 조회해 위험도 표시 목록을 만든다.
///
/// - 순수 함수: 입력만으로 출력이 결정되며 외부 상태를 읽거나 바꾸지 않는다.
/// - `catalog` 에 없는 key 는 건너뛴다(결과에서 제외).
/// - 결과는 `(riskSortRank(riskLevel) 오름차순, canonicalKey 오름차순)` 으로
///   정렬한다 — `List.sort` 는 안정 정렬을 보장하지 않으므로 동순위 tie-break
///   을 비교자에 명시한다.
List<IngredientRiskDisplay> buildRiskDisplayList(
  List<String> detectedKeys, {
  List<IngredientEntry> catalog = badIngredientCatalog,
}) {
  final entryByKey = {for (final entry in catalog) entry.canonicalKey: entry};

  final displays = <IngredientRiskDisplay>[];
  for (final key in detectedKeys) {
    final entry = entryByKey[key];
    if (entry == null) continue;
    displays.add(
      IngredientRiskDisplay(
        canonicalKey: entry.canonicalKey,
        reasonCode: entry.reasonCode,
        riskLevel: entry.riskLevel,
        riskReason: entry.riskReason,
        riskEvidence: entry.riskEvidence,
      ),
    );
  }

  displays.sort((a, b) {
    final rankCompare = riskSortRank(
      a.riskLevel,
    ).compareTo(riskSortRank(b.riskLevel));
    if (rankCompare != 0) return rankCompare;
    return a.canonicalKey.compareTo(b.canonicalKey);
  });

  return displays;
}
