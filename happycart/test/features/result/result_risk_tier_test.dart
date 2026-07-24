import 'package:flutter_test/flutter_test.dart';
import 'package:happycart/features/result/result_risk_tier.dart';
import 'package:happycart_rules/happycart_rules.dart';

IngredientRiskDisplay _display(String key, RiskLevel? level) =>
    IngredientRiskDisplay(
      canonicalKey: key,
      reasonCode: 'artificial_color',
      riskLevel: level,
      riskReason: null,
      riskEvidence: null,
    );

void main() {
  group('resolveRiskTier', () {
    test('RiskLevel.high 포함 목록이면 RiskTier.high', () {
      final displays = [
        _display('a', RiskLevel.high),
        _display('b', RiskLevel.low),
      ];
      expect(resolveRiskTier(displays), RiskTier.high);
    });

    test('최고가 RiskLevel.medium 이면 RiskTier.medium', () {
      final displays = [
        _display('a', RiskLevel.medium),
        _display('b', RiskLevel.low),
      ];
      expect(resolveRiskTier(displays), RiskTier.medium);
    });

    test('전부 RiskLevel.low 면 RiskTier.low', () {
      final displays = [
        _display('a', RiskLevel.low),
        _display('b', RiskLevel.low),
      ];
      expect(resolveRiskTier(displays), RiskTier.low);
    });

    test('빈 목록이면 RiskTier.medium (방어적)', () {
      expect(resolveRiskTier(const []), RiskTier.medium);
    });

    test('riskLevel 전부 null 이면 RiskTier.medium (방어적)', () {
      final displays = [_display('a', null), _display('b', null)];
      expect(resolveRiskTier(displays), RiskTier.medium);
    });
  });

  group('riskTierData', () {
    test('4개 tier 모두를 담는다', () {
      expect(riskTierData.keys.toSet(), RiskTier.values.toSet());
    });

    test('RiskTier.low 의 gaugeFilled 는 1', () {
      expect(riskTierData[RiskTier.low]!.gaugeFilled, 1);
    });

    test('RiskTier.high 의 gaugeFilled 는 3', () {
      expect(riskTierData[RiskTier.high]!.gaugeFilled, 3);
    });
  });
}
