/// HappyCart Good Ingredient 카탈로그 (스펙 §5.4).
///
/// clean-eating 철학상 "긍정 신호"로 보는 성분. verdict 산정에는 영향 없고
/// 결과 화면 부가 칩으로만 노출한다 (Okay·Not Okay 모두에 표시 가능).
library;

import 'bad_ingredients.dart' show IngredientEntry;

part 'good_ingredients.g.dart';

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
