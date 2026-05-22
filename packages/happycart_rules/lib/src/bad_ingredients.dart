/// HappyCart Bad Ingredient 카탈로그 (스펙 §5.3).
///
/// clean-eating 철학상 "Not Okay" 신호로 보는 성분. 매칭 1건 이상이면 verdict = notOkay.
/// 카테고리(reason code)별로 그룹핑하며, 각 canonical 키는 한·영·E-number alias 를 가진다.
///
/// alias 매칭 규칙:
/// - 한국어/영어 일반 alias: 토큰에 부분 문자열 포함 시 매칭.
/// - E-number alias (`E\d+` 형태): 정확 일치만 매칭 (E1400 ≠ E14000 보호).
library;

/// 카탈로그 한 엔트리.
class IngredientEntry {
  /// 내부 식별자 (DB 적재 시 사용). 예: `aspartame`, `hfcs`, `red_40`.
  final String canonicalKey;

  /// 사용자 표시·집계용 카테고리. 예: `artificial_sweetener`.
  final String reasonCode;

  /// 매칭 후보 — 한·영 표기와 E-number 를 모두 포함.
  final List<String> aliases;

  const IngredientEntry({
    required this.canonicalKey,
    required this.reasonCode,
    required this.aliases,
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
}

/// Bad ingredient 사전 (스펙 §5.3 표).
///
/// 카탈로그 순서는 결과 화면의 reason chip 표시 우선순위에도 사용된다 —
/// 더 강력한 신호(인공감미료, 합성 보존제)를 앞쪽에 둔다.
const List<IngredientEntry> badIngredientCatalog = [
  // === 인공 감미료 ===
  IngredientEntry(
    canonicalKey: 'aspartame',
    reasonCode: BadReasonCode.artificialSweetener,
    aliases: ['아스파탐', 'aspartame', 'E951'],
  ),
  IngredientEntry(
    canonicalKey: 'sucralose',
    reasonCode: BadReasonCode.artificialSweetener,
    aliases: ['수크랄로스', 'sucralose', 'E955'],
  ),
  IngredientEntry(
    canonicalKey: 'acesulfame_k',
    reasonCode: BadReasonCode.artificialSweetener,
    aliases: ['아세설팜칼륨', 'acesulfame', 'ace-k', 'acesulfame potassium', 'E950'],
  ),
  IngredientEntry(
    canonicalKey: 'saccharin',
    reasonCode: BadReasonCode.artificialSweetener,
    aliases: ['사카린', 'saccharin', 'E954'],
  ),

  // === 인공 색소 ===
  IngredientEntry(
    canonicalKey: 'red_40',
    reasonCode: BadReasonCode.artificialColor,
    aliases: ['적색40호', '적색 40호', 'red 40', 'allura red', 'E129'],
  ),
  IngredientEntry(
    canonicalKey: 'yellow_5',
    reasonCode: BadReasonCode.artificialColor,
    aliases: ['황색5호', '황색 5호', 'yellow 5', 'tartrazine', 'E102'],
  ),
  IngredientEntry(
    canonicalKey: 'yellow_6',
    reasonCode: BadReasonCode.artificialColor,
    aliases: ['황색6호', '황색 6호', 'yellow 6', 'sunset yellow', 'E110'],
  ),
  IngredientEntry(
    canonicalKey: 'blue_1',
    reasonCode: BadReasonCode.artificialColor,
    aliases: ['청색1호', '청색 1호', 'blue 1', 'brilliant blue', 'E133'],
  ),
  IngredientEntry(
    canonicalKey: 'red_3',
    reasonCode: BadReasonCode.artificialColor,
    aliases: ['적색3호', '적색 3호', 'red 3', 'erythrosine', 'E127'],
  ),

  // === HFCS ===
  IngredientEntry(
    canonicalKey: 'hfcs',
    reasonCode: BadReasonCode.hfcs,
    aliases: [
      '고과당옥수수시럽',
      '액상과당',
      '과당시럽',
      '콘시럽',
      'high fructose corn syrup',
      'hfcs',
      'corn syrup',
    ],
  ),

  // === 정제 씨앗유 ===
  IngredientEntry(
    canonicalKey: 'soybean_oil',
    reasonCode: BadReasonCode.seedOil,
    aliases: ['대두유', '콩기름', '대두기름', 'soybean oil'],
  ),
  IngredientEntry(
    canonicalKey: 'canola_oil',
    reasonCode: BadReasonCode.seedOil,
    aliases: ['카놀라유', '채종유', 'canola oil', 'rapeseed oil'],
  ),
  IngredientEntry(
    canonicalKey: 'corn_oil',
    reasonCode: BadReasonCode.seedOil,
    aliases: ['옥수수유', '옥수수기름', 'corn oil'],
  ),
  IngredientEntry(
    canonicalKey: 'sunflower_oil_refined',
    reasonCode: BadReasonCode.seedOil,
    aliases: ['정제 해바라기씨유', '정제해바라기씨유', 'refined sunflower oil'],
  ),
  IngredientEntry(
    canonicalKey: 'cottonseed_oil',
    reasonCode: BadReasonCode.seedOil,
    aliases: ['면실유', 'cottonseed oil'],
  ),

  // === 경화유 ===
  IngredientEntry(
    canonicalKey: 'hydrogenated',
    reasonCode: BadReasonCode.hydrogenatedOil,
    aliases: [
      '경화유',
      '부분경화유',
      '부분 경화유',
      'hydrogenated',
      'partially hydrogenated',
      '트랜스지방',
    ],
  ),

  // === 합성 보존제 ===
  IngredientEntry(
    canonicalKey: 'bha',
    reasonCode: BadReasonCode.syntheticPreservative,
    aliases: ['bha', '부틸하이드록시아니솔', 'butylated hydroxyanisole', 'E320'],
  ),
  IngredientEntry(
    canonicalKey: 'bht',
    reasonCode: BadReasonCode.syntheticPreservative,
    aliases: ['bht', '부틸하이드록시톨루엔', 'butylated hydroxytoluene', 'E321'],
  ),
  IngredientEntry(
    canonicalKey: 'tbhq',
    reasonCode: BadReasonCode.syntheticPreservative,
    aliases: [
      'tbhq',
      '터셔리부틸하이드로퀴논',
      'tert-butylhydroquinone',
      'E319',
    ],
  ),

  // === 질산염 / 아질산염 ===
  IngredientEntry(
    canonicalKey: 'sodium_nitrite',
    reasonCode: BadReasonCode.nitrite,
    aliases: ['아질산나트륨', 'sodium nitrite', 'E250'],
  ),
  IngredientEntry(
    canonicalKey: 'sodium_nitrate',
    reasonCode: BadReasonCode.nitrite,
    // 한국 라벨에서 '질산나트륨' 단독 표기는 드물고, '아질산나트륨'과 substring
    // 충돌이 발생한다. 영문 / E-number alias 만 사용.
    aliases: ['sodium nitrate', 'E251'],
  ),

  // === 카라기난 ===
  IngredientEntry(
    canonicalKey: 'carrageenan',
    reasonCode: BadReasonCode.carrageenan,
    aliases: ['카라기난', 'carrageenan', 'E407'],
  ),

  // === 유화제 / 안정제 ===
  IngredientEntry(
    canonicalKey: 'polysorbate_80',
    reasonCode: BadReasonCode.emulsifierConcern,
    aliases: ['폴리소르베이트80', '폴리소르베이트 80', 'polysorbate 80', 'E433'],
  ),
  IngredientEntry(
    canonicalKey: 'datem',
    reasonCode: BadReasonCode.emulsifierConcern,
    aliases: ['datem', '다템'],
  ),
  IngredientEntry(
    canonicalKey: 'mono_diglycerides',
    reasonCode: BadReasonCode.emulsifierConcern,
    aliases: [
      '모노글리세리드',
      '디글리세리드',
      'mono- and diglycerides',
      'monoglycerides',
      'diglycerides',
      'E471',
    ],
  ),

  // === 모호한 향료 ===
  IngredientEntry(
    canonicalKey: 'natural_flavors_opaque',
    reasonCode: BadReasonCode.opaqueFlavor,
    aliases: ['natural flavors', '천연향료'],
  ),
  IngredientEntry(
    canonicalKey: 'artificial_flavors',
    reasonCode: BadReasonCode.opaqueFlavor,
    aliases: ['합성착향료', '인공향료', 'artificial flavors', 'artificial flavor'],
  ),

  // === 정제 곡물 ===
  IngredientEntry(
    canonicalKey: 'bleached_flour',
    reasonCode: BadReasonCode.refinedFlour,
    aliases: ['표백 밀가루', '표백밀가루', 'bleached flour'],
  ),
  IngredientEntry(
    canonicalKey: 'enriched_flour',
    reasonCode: BadReasonCode.refinedFlour,
    aliases: ['강화 밀가루', '강화밀가루', 'enriched flour'],
  ),

  // === 브롬산칼륨 ===
  IngredientEntry(
    canonicalKey: 'potassium_bromate',
    reasonCode: BadReasonCode.bromate,
    aliases: ['브롬산칼륨', 'potassium bromate', 'E924'],
  ),

  // === 말토덱스트린 ===
  IngredientEntry(
    canonicalKey: 'maltodextrin',
    reasonCode: BadReasonCode.maltodextrin,
    aliases: ['말토덱스트린', 'maltodextrin', 'E1400'],
  ),
];
