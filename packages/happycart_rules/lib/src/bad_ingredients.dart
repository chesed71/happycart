/// HappyCart Bad Ingredient 카탈로그 (스펙 §5.3).
///
/// clean-eating 철학상 "Not Okay" 신호로 보는 성분. 매칭 1건 이상이면 verdict = notOkay.
/// 카테고리(reason code)별로 그룹핑하며, 각 canonical 키는 한·영·E-number alias 를 가진다.
///
/// alias 매칭 규칙:
/// - 한국어/영어 일반 alias: 토큰에 부분 문자열 포함 시 매칭.
/// - E-number alias (`E\d+` 형태): 정확 일치만 매칭 (E1400 ≠ E14000 보호).
library;

part 'bad_ingredients.g.dart';

/// 성분 건강 위험도 등급.
enum RiskLevel { high, medium, low }

/// wire 문자열(소문자) → [RiskLevel]. 3종(`high`/`medium`/`low`) 외 값은
/// [ArgumentError] 를 던진다.
RiskLevel riskLevelFromWire(String wire) {
  switch (wire) {
    case 'high':
      return RiskLevel.high;
    case 'medium':
      return RiskLevel.medium;
    case 'low':
      return RiskLevel.low;
    default:
      throw ArgumentError.value(wire, 'wire', '알 수 없는 RiskLevel wire 값');
  }
}

/// [RiskLevel] → wire 문자열(소문자).
String riskLevelToWire(RiskLevel level) {
  switch (level) {
    case RiskLevel.high:
      return 'high';
    case RiskLevel.medium:
      return 'medium';
    case RiskLevel.low:
      return 'low';
  }
}

/// 정렬용 순위: high=0, medium=1, low=2, null(미분류)=3(최하위).
int riskSortRank(RiskLevel? level) {
  switch (level) {
    case RiskLevel.high:
      return 0;
    case RiskLevel.medium:
      return 1;
    case RiskLevel.low:
      return 2;
    case null:
      return 3;
  }
}

/// 카탈로그 한 엔트리.
class IngredientEntry {
  /// 내부 식별자 (DB 적재 시 사용). 예: `aspartame`, `hfcs`, `red_40`.
  final String canonicalKey;

  /// 사용자 표시·집계용 카테고리. 예: `artificial_sweetener`.
  final String reasonCode;

  /// 사용자 표시용 한글 라벨(카탈로그 단일소스). 예: `아스파탐`, `황색4호`.
  final String label;

  /// 매칭 후보 — 한·영 표기와 E-number 를 모두 포함.
  final List<String> aliases;

  /// 건강 위험도 등급 (미분류 시 null). good 카탈로그 엔트리는 항상 null.
  final RiskLevel? riskLevel;

  /// 위험도 판정 사유(표시용 텍스트).
  final String? riskReason;

  /// 위험도 판정 근거(표시용 텍스트).
  final String? riskEvidence;

  const IngredientEntry({
    required this.canonicalKey,
    required this.reasonCode,
    required this.label,
    required this.aliases,
    this.riskLevel,
    this.riskReason,
    this.riskEvidence,
  });
}

/// reason code 상수. UI 문구 매핑·집계 모두 같은 키를 쓴다.
class BadReasonCode {
  BadReasonCode._();

  static const artificialSweetener = 'artificial_sweetener';
  static const artificialColor = 'artificial_color';
  static const hfcs = 'hfcs';
  static const seedOil = 'seed_oil';
  static const hydrogenatedOil = 'hydrogenated_oil';
  static const syntheticPreservative = 'synthetic_preservative';
  static const nitrite = 'nitrite';
  static const carrageenan = 'carrageenan';
  static const emulsifierConcern = 'emulsifier_concern';
  static const opaqueFlavor = 'opaque_flavor';
  static const refinedFlour = 'refined_flour';
  static const bromate = 'bromate';
  static const maltodextrin = 'maltodextrin';
  static const refinedSugar = 'refined_sugar';
}
