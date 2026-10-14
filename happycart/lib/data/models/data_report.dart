/// 데이터 오류 신고 payload.
///
/// 전송되는 값은 전부 앱이 미리 정한 열거형이거나 해당 제품의 라벨 원문
/// 조각이다. 사용자가 입력한 글은 받지 않는다 (마이그레이션 0023 주석 참고).
library;

/// 신고 사유. `code` 는 DB enum `data_report_reason_enum` 의 값과 1:1 이다.
enum ReportReason {
  /// 성분표가 제품과 달라요.
  ingredientsMismatch('ingredients_mismatch'),

  /// 이 성분은 위험하지 않아요 (잠깐 경로).
  notRisky('not_risky'),

  /// 빠진 주의 성분이 있어요 (괜찮아요 경로).
  missingRisky('missing_risky'),

  /// 다른 제품 정보예요.
  wrongProduct('wrong_product'),

  /// 그 밖에 달라요.
  other('other'),

  /// 미등록 제품 등록 요청 (미등록 화면 전용).
  registerRequest('register_request');

  const ReportReason(this.code);

  final String code;
}

/// 사용자가 지목한 성분 1건.
///
/// 중립 성분은 룰 매칭이 없어 [canonicalKey] 가 `null` 이다
/// (`ingredient_table.dart` 의 `IngredientTableEntry.canonicalKey`).
/// 그래서 라벨 원문 조각 [text] 를 항상 함께 보낸다.
class ReportedIngredient {
  final String text;
  final String? canonicalKey;

  const ReportedIngredient({required this.text, this.canonicalKey});

  Map<String, dynamic> toJson() => {
        'text': text,
        if (canonicalKey != null) 'key': canonicalKey,
      };
}
