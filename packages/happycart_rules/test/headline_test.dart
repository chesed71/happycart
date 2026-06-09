import 'package:happycart_rules/happycart_rules.dart';
import 'package:test/test.dart';

void main() {
  group('computeHeadline', () {
    test('okay → "마음 편히 담아도 괜찮아요"', () {
      const result = VerdictResult(verdict: Verdict.okay);
      expect(computeHeadline(result), '마음 편히 담아도 괜찮아요');
    });

    test('notOkay → "잠깐, 이런 성분이 들어 있어요"', () {
      const result = VerdictResult(verdict: Verdict.notOkay);
      expect(computeHeadline(result), '잠깐, 이런 성분이 들어 있어요');
    });

    test('insufficient → "이 제품의 원재료 정보를 확인하지 못했어요"', () {
      const result = VerdictResult(verdict: Verdict.insufficient);
      expect(computeHeadline(result), '이 제품의 원재료 정보를 확인하지 못했어요');
    });
  });

  group('verdictLabel', () {
    test('okay label', () => expect(verdictLabel(Verdict.okay), '괜찮아요'));
    test('notOkay label', () => expect(verdictLabel(Verdict.notOkay), '잠깐'));
    test('insufficient label',
        () => expect(verdictLabel(Verdict.insufficient), '판단 보류'));
  });

  group('reasonCodeLabel', () {
    test('artificial_sweetener', () {
      expect(reasonCodeLabel(BadReasonCode.artificialSweetener), '인공 감미료');
    });
    test('seed_oil', () {
      expect(reasonCodeLabel(BadReasonCode.seedOil), '정제 씨앗유');
    });
    test('hydrogenated_oil', () {
      expect(reasonCodeLabel(BadReasonCode.hydrogenatedOil), '경화유 / 트랜스지방');
    });
    test('refined_sugar (v1.1.0)', () {
      expect(reasonCodeLabel(BadReasonCode.refinedSugar), '정제 설탕');
    });
    test('unknown reason code falls back to the code itself', () {
      expect(reasonCodeLabel('unknown_reason'), 'unknown_reason');
    });
  });

  test('notFoundMessage', () {
    expect(notFoundMessage, '해피카트에서 이 물건을 찾을 수 없습니다');
  });
}
