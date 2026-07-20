import 'package:happycart_rules/happycart_rules.dart';
import 'package:test/test.dart';

void main() {
  group('RiskLevel wire 변환', () {
    test('riskLevelToWire ↔ riskLevelFromWire 3종 왕복 일치', () {
      for (final level in RiskLevel.values) {
        expect(riskLevelFromWire(riskLevelToWire(level)), level);
      }
    });

    test('riskLevelFromWire("bogus") → ArgumentError', () {
      expect(() => riskLevelFromWire('bogus'), throwsArgumentError);
    });
  });

  group('riskSortRank', () {
    test('high=0, medium=1, low=2, null=3', () {
      expect(riskSortRank(RiskLevel.high), 0);
      expect(riskSortRank(RiskLevel.medium), 1);
      expect(riskSortRank(RiskLevel.low), 2);
      expect(riskSortRank(null), 3);
    });
  });

  group('IngredientEntry 위험도 필드', () {
    test('risk 필드 미지정 시 세 필드 모두 null', () {
      const entry = IngredientEntry(
        canonicalKey: 'test_key',
        reasonCode: 'test_reason',
        label: '테스트',
        aliases: ['test'],
      );
      expect(entry.riskLevel, isNull);
      expect(entry.riskReason, isNull);
      expect(entry.riskEvidence, isNull);
    });
  });

  group('buildRiskDisplayList', () {
    const catalog = [
      IngredientEntry(
        canonicalKey: 'low_key',
        reasonCode: 'reason_a',
        label: '낮음성분',
        aliases: ['low'],
        riskLevel: RiskLevel.low,
        riskReason: '낮음 사유',
        riskEvidence: '낮음 근거',
      ),
      IngredientEntry(
        canonicalKey: 'high_key',
        reasonCode: 'reason_b',
        label: '높음성분',
        aliases: ['high'],
        riskLevel: RiskLevel.high,
        riskReason: '높음 사유',
        riskEvidence: '높음 근거',
      ),
      IngredientEntry(
        canonicalKey: 'medium_b_key',
        reasonCode: 'reason_c',
        label: '보통성분B',
        aliases: ['medium_b'],
        riskLevel: RiskLevel.medium,
        riskReason: '보통 사유 B',
        riskEvidence: '보통 근거 B',
      ),
      IngredientEntry(
        canonicalKey: 'medium_a_key',
        reasonCode: 'reason_d',
        label: '보통성분A',
        aliases: ['medium_a'],
        riskLevel: RiskLevel.medium,
        riskReason: '보통 사유 A',
        riskEvidence: '보통 근거 A',
      ),
      IngredientEntry(
        canonicalKey: 'null_key',
        reasonCode: 'reason_e',
        label: 'null성분',
        aliases: ['null_risk'],
      ),
    ];

    test('위험도 내림차순(high→medium→low→null) 정렬', () {
      final result = buildRiskDisplayList([
        'low_key',
        'high_key',
        'medium_b_key',
        'medium_a_key',
        'null_key',
      ], catalog: catalog);
      expect(result.map((e) => e.canonicalKey).toList(), [
        'high_key',
        'medium_a_key',
        'medium_b_key',
        'low_key',
        'null_key',
      ]);
    });

    test('동일 riskLevel 2건은 canonicalKey 오름차순 tie-break', () {
      final result = buildRiskDisplayList([
        'medium_b_key',
        'medium_a_key',
      ], catalog: catalog);
      expect(result.map((e) => e.canonicalKey).toList(), [
        'medium_a_key',
        'medium_b_key',
      ]);
    });

    test('riskLevel null 엔트리는 정렬 최하위', () {
      final result = buildRiskDisplayList([
        'null_key',
        'high_key',
      ], catalog: catalog);
      expect(result.map((e) => e.canonicalKey).toList(), [
        'high_key',
        'null_key',
      ]);
    });

    test('catalog 미등록 key 는 결과에서 제외', () {
      final result = buildRiskDisplayList([
        'high_key',
        'no_such_key',
        'low_key',
      ], catalog: catalog);
      expect(result.map((e) => e.canonicalKey).toList(), [
        'high_key',
        'low_key',
      ]);
    });

    test('IngredientRiskDisplay 필드가 카탈로그 값을 그대로 담는다', () {
      final result = buildRiskDisplayList(['high_key'], catalog: catalog);
      expect(result, hasLength(1));
      final display = result.single;
      expect(display.canonicalKey, 'high_key');
      expect(display.reasonCode, 'reason_b');
      expect(display.riskLevel, RiskLevel.high);
      expect(display.riskReason, '높음 사유');
      expect(display.riskEvidence, '높음 근거');
    });
  });
}
