import 'package:happycart/core/verdict.dart';
import 'package:happycart_rules/happycart_rules.dart';

/// 결과 화면이 표시하는 1건 조회 결과 (스펙 §4.2 `lookup_product` 반환 컬럼).
///
/// `lookup_product` RPC가 0행을 돌려주면 호출자는 `null` 을 받게 되므로,
/// 이 클래스는 항상 "1행 매핑 결과"만 표현한다. 미등록/네트워크 오류 등
/// 다른 상태는 호출 측 (ScanController 등) 에서 별도 sealed state 로 분기한다.
class ProductLookupResult {
  /// 13자리(EAN-13) 또는 8자리(EAN-8) 바코드.
  final String barcode;

  /// 브랜드.
  final String brand;

  /// 제품명.
  final String name;

  /// 용량 라벨 (예: `500ml`).
  final String size;

  /// 카테고리 (예: "올리브오일") — nullable.
  final String? category;

  /// 룰 패키지가 결정한 최종 평가.
  final Verdict verdict;

  /// 매칭된 bad ingredient canonical key 리스트.
  final List<String> badIngredients;

  /// 매칭된 good ingredient canonical key 리스트 (부가 칩 노출용).
  final List<String> goodIngredients;

  /// 매칭된 reason code 리스트 (chip 그룹 헤더 매핑용).
  final List<String> reasonCodes;

  /// 룰 버전 (예: `v1.0.0`).
  final String ruleVersion;

  /// 룰이 재계산된 시각 (UTC).
  final DateTime computedAt;

  /// 원본 데이터 확인 시각 (UTC) — 결과 화면 "마지막 업데이트" 표기.
  final DateTime sourceCheckedAt;

  const ProductLookupResult({
    required this.barcode,
    required this.brand,
    required this.name,
    required this.size,
    required this.verdict,
    required this.ruleVersion,
    required this.computedAt,
    required this.sourceCheckedAt,
    this.category,
    this.badIngredients = const [],
    this.goodIngredients = const [],
    this.reasonCodes = const [],
  });

  /// `lookup_product` RPC 한 행 (`Map<String, dynamic>`) → 모델 변환.
  ///
  /// 잘못된 verdict 문자열이 들어오면 `ArgumentError` 가 던져진다 — RPC
  /// 응답이 깨졌다는 뜻이므로 호출 측에서 NetworkException 으로 래핑하는
  /// 것이 자연스럽다.
  factory ProductLookupResult.fromRpcRow(Map<String, dynamic> row) {
    List<String> asStringList(Object? raw) {
      if (raw is List) {
        return raw.map((e) => e.toString()).toList(growable: false);
      }
      return const <String>[];
    }

    return ProductLookupResult(
      barcode: row['barcode'] as String,
      brand: row['brand'] as String,
      name: row['name'] as String,
      size: row['size'] as String,
      category: row['category'] as String?,
      verdict: verdictFromWire(row['verdict'] as String),
      badIngredients: asStringList(row['bad_ingredients_detected']),
      goodIngredients: asStringList(row['good_ingredients_detected']),
      reasonCodes: asStringList(row['verdict_reason_codes']),
      ruleVersion: row['rule_version'] as String,
      computedAt: DateTime.parse(row['computed_at'] as String).toUtc(),
      sourceCheckedAt:
          DateTime.parse(row['source_checked_at'] as String).toUtc(),
    );
  }

  @override
  String toString() =>
      'ProductLookupResult(barcode: $barcode, name: $name, '
      'verdict: $verdict, bad: $badIngredients)';
}
