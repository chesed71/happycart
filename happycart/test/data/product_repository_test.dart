import 'package:flutter_test/flutter_test.dart';
import 'package:happycart/data/product_repository.dart';
import 'package:happycart_rules/happycart_rules.dart';

Map<String, dynamic> _row({String? imageUrl, Object? ingredientsRaw = _absent}) =>
    {
      'barcode': '8809990172030',
      'brand': '웰코리아',
      'name': '사이다볼',
      'size': '9g',
      'category': '캔디류',
      'verdict': 'not_okay',
      'bad_ingredients_detected': ['blue_1', 'sugar'],
      'good_ingredients_detected': <String>[],
      'verdict_reason_codes': ['artificial_color', 'refined_sugar'],
      'rule_version': 'v1.1.0',
      'computed_at': '2026-05-26T03:23:24Z',
      'source_checked_at': '2026-05-26T03:18:11.482068+00:00',
      'image_url': imageUrl,
      // _absent 이면 키 자체를 넣지 않아 구 RPC(컬럼 부재)를 재현한다.
      if (ingredientsRaw != _absent) 'ingredients_raw': ingredientsRaw,
    };

/// _row 에서 "키를 아예 넣지 않음"과 "null 로 넣음"을 구분하기 위한 센티넬.
const Object _absent = Object();

void main() {
  test('lookupByBarcode maps product image URL from RPC rows', () async {
    final repo = ProductRepository.forTesting(
      rpc: (_, {params}) async => [
        _row(imageUrl: 'https://thumbnail.coupangcdn.com/product.jpg'),
      ],
    );

    final product = await repo.lookupByBarcode('8809990172030');

    expect(product, isNotNull);
    expect(product!.imageUrl, 'https://thumbnail.coupangcdn.com/product.jpg');
    expect(product.verdict, Verdict.notOkay);
  });

  test('lookupByBarcode keeps image URL nullable for older rows', () async {
    final repo = ProductRepository.forTesting(
      rpc: (_, {params}) async => [_row()],
    );

    final product = await repo.lookupByBarcode('8809990172030');

    expect(product, isNotNull);
    expect(product!.imageUrl, isNull);
  });

  test('lookupByBarcode maps ingredients_raw from RPC rows', () async {
    final repo = ProductRepository.forTesting(
      rpc: (_, {params}) async => [_row(ingredientsRaw: '정제수, 설탕, 아스파탐')],
    );

    final product = await repo.lookupByBarcode('8809990172030');

    expect(product!.ingredientsRaw, '정제수, 설탕, 아스파탐');
  });

  test('lookupByBarcode falls back to empty ingredients_raw for older rows', () async {
    final repo = ProductRepository.forTesting(
      rpc: (_, {params}) async => [_row()],
    );

    final product = await repo.lookupByBarcode('8809990172030');

    expect(product!.ingredientsRaw, '');
  });
}
