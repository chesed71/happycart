import 'package:flutter_test/flutter_test.dart';
import 'package:happycart/features/result/ingredient_table.dart';

void main() {
  group('buildIngredientTable', () {
    test('최상위 쉼표만 분리 — 괄호 안 쉼표는 하위 성분으로 보존', () {
      final entries = buildIngredientTable(
        '밀가루(밀:미국산,호주산), 설탕',
        badKeys: const ['sugar'],
        goodKeys: const [],
      );
      expect(
        entries.map((e) => e.text).toList(),
        ['밀가루(밀:미국산,호주산)', '설탕'],
      );
    });

    test('서버 판정 bad 키에 해당하는 조각만 bad 로 강조', () {
      final entries = buildIngredientTable(
        '정제수, 아스파탐, 설탕',
        badKeys: const ['aspartame'],
        goodKeys: const [],
      );
      final byText = {for (final e in entries) e.text: e};

      expect(byText['정제수']!.mark, IngredientMark.neutral);
      expect(byText['아스파탐']!.mark, IngredientMark.bad);
      expect(byText['아스파탐']!.canonicalKey, 'aspartame');
      // 설탕은 sugar 로 매칭되지만 badKeys 에 없으므로 강조하지 않는다(스큐 방어).
      expect(byText['설탕']!.mark, IngredientMark.neutral);
    });

    test('good 키에 해당하는 조각은 good 로 강조', () {
      final entries = buildIngredientTable(
        '아보카도오일, 정제수',
        badKeys: const [],
        goodKeys: const ['avocado_oil'],
      );
      final byText = {for (final e in entries) e.text: e};

      expect(byText['아보카도오일']!.mark, IngredientMark.good);
      expect(byText['아보카도오일']!.canonicalKey, 'avocado_oil');
      expect(byText['정제수']!.mark, IngredientMark.neutral);
    });

    test('빈/공백 조각은 건너뛴다', () {
      final entries = buildIngredientTable(
        '설탕, , ',
        badKeys: const ['sugar'],
        goodKeys: const [],
      );
      expect(entries.length, 1);
      expect(entries.first.text, '설탕');
      expect(entries.first.mark, IngredientMark.bad);
    });

    test('닫히지 않은 괄호(malformed) — 정상 조각은 보존, 안 닫힌 뒷부분은 원문 그대로 한 조각', () {
      // best-effort: 억지 재분리로 정상 괄호 그룹을 깨지 않는다. 앞의 정상 분리
      // ("설탕", "밀가루(밀:미국산,호주산)")는 그대로 유지되고, 안 닫힌 괄호부터는
      // 원문 그대로 한 조각("향료(잔여, 물")으로 노출한다.
      final entries = buildIngredientTable(
        '설탕, 밀가루(밀:미국산,호주산), 향료(잔여, 물',
        badKeys: const [],
        goodKeys: const [],
      );
      expect(
        entries.map((e) => e.text).toList(),
        ['설탕', '밀가루(밀:미국산,호주산)', '향료(잔여, 물'],
      );
    });
  });
}
