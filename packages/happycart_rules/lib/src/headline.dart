import 'bad_ingredients.dart' show BadReasonCode;
import 'verdict.dart';

/// verdict 결과 → 결과 화면 한 줄 카피 (스펙 §5.6).
///
/// - okay: "마음 편히 담아도 괜찮아요"
/// - notOkay: "잠깐, 이런 성분이 들어 있어요"
/// - insufficient: "이 제품의 원재료 정보를 확인하지 못했어요"
String computeHeadline(VerdictResult result) {
  switch (result.verdict) {
    case Verdict.okay:
      return '마음 편히 담아도 괜찮아요';
    case Verdict.notOkay:
      return '잠깐, 이런 성분이 들어 있어요';
    case Verdict.insufficient:
      return '이 제품의 원재료 정보를 확인하지 못했어요';
  }
}

/// not_found 상태 메시지 (스펙 §5.6).
const String notFoundMessage = '해피카트에서 이 물건을 찾을 수 없습니다';

/// 사용자 표시용 verdict 라벨 (스펙 §15 확정 사항: "괜찮아요" / "잠깐").
String verdictLabel(Verdict verdict) {
  switch (verdict) {
    case Verdict.okay:
      return '괜찮아요';
    case Verdict.notOkay:
      return '잠깐';
    case Verdict.insufficient:
      return '판단 보류';
  }
}

/// reason code 한국어 라벨 (Not Okay 결과 화면의 chip 그룹 헤더용).
String reasonCodeLabel(String reasonCode) {
  switch (reasonCode) {
    case BadReasonCode.artificialSweetener:
      return '인공 감미료';
    case BadReasonCode.artificialColor:
      return '인공 색소';
    case BadReasonCode.hfcs:
      return '고과당 옥수수시럽';
    case BadReasonCode.seedOil:
      return '정제 씨앗유';
    case BadReasonCode.hydrogenatedOil:
      return '경화유 / 트랜스지방';
    case BadReasonCode.syntheticPreservative:
      return '합성 보존제';
    case BadReasonCode.nitrite:
      return '아질산염 / 질산염';
    case BadReasonCode.carrageenan:
      return '카라기난';
    case BadReasonCode.emulsifierConcern:
      return '유화제 / 안정제';
    case BadReasonCode.opaqueFlavor:
      return '향료 (성분 비공개)';
    case BadReasonCode.refinedFlour:
      return '정제 밀가루';
    case BadReasonCode.bromate:
      return '브롬산칼륨';
    case BadReasonCode.maltodextrin:
      return '말토덱스트린';
    case BadReasonCode.refinedSugar:
      return '정제 설탕';
    default:
      return reasonCode;
  }
}
