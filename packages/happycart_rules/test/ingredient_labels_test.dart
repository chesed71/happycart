import 'package:happycart_rules/happycart_rules.dart';
import 'package:test/test.dart';

void main() {
  group('canonicalLabel', () {
    test('옛 _canonicalLabel switch 이관 라벨을 그대로 반환한다(회귀)', () {
      expect(canonicalLabel('aspartame'), '아스파탐');
      expect(canonicalLabel('yellow_5'), '황색4호'); // KR 번호 교정(타트라진)
      expect(canonicalLabel('yellow_6'), '황색5호'); // 선셋옐로
      expect(canonicalLabel('hydrogenated'), '경화유 / 트랜스지방');
      expect(canonicalLabel('natural_flavors_opaque'), '천연향료 (성분 비공개)');
      expect(canonicalLabel('pasture_raised_egg'), '방목 달걀');
    });

    test('옛 switch 에 없던 신규 키 sugar 는 설탕', () {
      expect(canonicalLabel('sugar'), '설탕');
    });

    test('미등록 key 는 key 원문으로 폴백', () {
      expect(canonicalLabel('없는키_xyz'), '없는키_xyz');
    });
  });

  group('ingredientLabelByKey', () {
    test('bad+good 전 엔트리를 담고 모든 라벨이 비어있지 않다', () {
      final total = badIngredientCatalog.length + goodIngredientCatalog.length;
      expect(ingredientLabelByKey.length, total);
      expect(
        ingredientLabelByKey.values.every((v) => v.trim().isNotEmpty),
        isTrue,
      );
    });
  });
}
