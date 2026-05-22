/// HappyCart Good Ingredient 카탈로그 (스펙 §5.4).
///
/// clean-eating 철학상 "긍정 신호"로 보는 성분. verdict 산정에는 영향 없고
/// 결과 화면 부가 칩으로만 노출한다 (Okay·Not Okay 모두에 표시 가능).
library;

import 'bad_ingredients.dart' show IngredientEntry;

/// good 측 reason code 상수.
class GoodReasonCode {
  GoodReasonCode._();

  static const cleanFat = 'clean_fat';
  static const naturalSweetener = 'natural_sweetener';
  static const naturalSalt = 'natural_salt';
  static const wholeFood = 'whole_food';
  static const organic = 'organic';
  static const fermented = 'fermented';
  static const wholeGrain = 'whole_grain';
  static const pastureRaised = 'pasture_raised';
  static const grassFed = 'grass_fed';
}

/// Good ingredient 사전 (스펙 §5.4 표).
const List<IngredientEntry> goodIngredientCatalog = [
  // === 좋은 지방 ===
  IngredientEntry(
    canonicalKey: 'extra_virgin_olive_oil',
    reasonCode: GoodReasonCode.cleanFat,
    aliases: ['엑스트라버진 올리브유', '엑스트라 버진 올리브유', 'evoo', 'extra virgin olive oil'],
  ),
  IngredientEntry(
    canonicalKey: 'avocado_oil',
    reasonCode: GoodReasonCode.cleanFat,
    aliases: ['아보카도 오일', '아보카도오일', 'avocado oil'],
  ),
  IngredientEntry(
    canonicalKey: 'coconut_oil',
    reasonCode: GoodReasonCode.cleanFat,
    aliases: ['코코넛 오일', '코코넛오일', 'coconut oil'],
  ),
  IngredientEntry(
    canonicalKey: 'grass_fed_butter',
    reasonCode: GoodReasonCode.cleanFat,
    aliases: [
      '그래스페드 버터',
      '그래스 페드 버터',
      'grass-fed butter',
      'grass fed butter',
      '기 버터',
      'ghee',
    ],
  ),

  // === 자연 감미료 ===
  IngredientEntry(
    canonicalKey: 'honey',
    reasonCode: GoodReasonCode.naturalSweetener,
    aliases: ['꿀', 'honey'],
  ),
  IngredientEntry(
    canonicalKey: 'maple_syrup',
    reasonCode: GoodReasonCode.naturalSweetener,
    aliases: ['메이플시럽', '메이플 시럽', 'maple syrup'],
  ),
  IngredientEntry(
    canonicalKey: 'date',
    reasonCode: GoodReasonCode.naturalSweetener,
    aliases: ['대추야자', 'dates', 'medjool'],
  ),

  // === 천일염 ===
  IngredientEntry(
    canonicalKey: 'sea_salt',
    reasonCode: GoodReasonCode.naturalSalt,
    aliases: ['천일염', 'sea salt'],
  ),

  // === 통곡물 ===
  IngredientEntry(
    canonicalKey: 'whole_grain',
    reasonCode: GoodReasonCode.wholeGrain,
    aliases: ['통곡물', '통밀', 'whole grain', 'whole wheat'],
  ),
  IngredientEntry(
    canonicalKey: 'sprouted_grain',
    reasonCode: GoodReasonCode.wholeGrain,
    aliases: ['발아곡물', 'sprouted grain', 'sprouted wheat'],
  ),

  // === 발효식품 ===
  IngredientEntry(
    canonicalKey: 'kimchi',
    reasonCode: GoodReasonCode.fermented,
    aliases: ['김치', 'kimchi'],
  ),
  IngredientEntry(
    canonicalKey: 'kefir',
    reasonCode: GoodReasonCode.fermented,
    aliases: ['케피어', 'kefir'],
  ),
  IngredientEntry(
    canonicalKey: 'sauerkraut',
    reasonCode: GoodReasonCode.fermented,
    aliases: ['사우어크라우트', 'sauerkraut'],
  ),
  IngredientEntry(
    canonicalKey: 'kombucha',
    reasonCode: GoodReasonCode.fermented,
    aliases: ['콤부차', 'kombucha'],
  ),

  // === 유기농 / pasture / grass-fed ===
  IngredientEntry(
    canonicalKey: 'organic',
    reasonCode: GoodReasonCode.organic,
    aliases: ['유기농', 'organic'],
  ),
  IngredientEntry(
    canonicalKey: 'pasture_raised_egg',
    reasonCode: GoodReasonCode.pastureRaised,
    aliases: ['방목 달걀', '방목달걀', 'pasture-raised egg', 'pasture raised egg', 'free-range egg'],
  ),
  IngredientEntry(
    canonicalKey: 'grass_fed_beef',
    reasonCode: GoodReasonCode.grassFed,
    aliases: ['그래스페드 소고기', 'grass-fed beef', 'grass fed beef'],
  ),
];
