/// 카탈로그(단일소스) 유래 canonicalKey → 한글 표시 라벨 조회.
///
/// 라벨은 `data/ingredient_catalog.json` 각 엔트리의 `label` 필드가 유일 소스이며,
/// generator 가 구운 `IngredientEntry.label` 을 그대로 읽는다. 미등록 key 는
/// key 원문으로 폴백한다(앱의 옛 `_canonicalLabel` default 동작과 동형).
library;

import 'bad_ingredients.dart';
import 'good_ingredients.dart';

/// bad + good 카탈로그를 합친 `{canonicalKey: label}` 맵.
final Map<String, String> ingredientLabelByKey = {
  for (final e in badIngredientCatalog) e.canonicalKey: e.label,
  for (final e in goodIngredientCatalog) e.canonicalKey: e.label,
};

/// canonicalKey 의 한글 표시 라벨. 미등록 key 는 key 원문 폴백.
String canonicalLabel(String canonicalKey) =>
    ingredientLabelByKey[canonicalKey] ?? canonicalKey;
