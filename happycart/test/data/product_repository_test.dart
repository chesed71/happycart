import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:happycart/data/models/data_report.dart';
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

  test('reportDataError sends reason code and pointed ingredients', () async {
    String? seenFn;
    Map<String, dynamic>? seenParams;
    final repo = ProductRepository.forTesting(
      rpc: (fn, {params}) async {
        seenFn = fn;
        seenParams = params;
        return null;
      },
    );

    final ok = await repo.reportDataError(
      barcode: '8809990172030',
      reason: ReportReason.ingredientsMismatch,
      ingredients: const [
        ReportedIngredient(text: '아스파탐', canonicalKey: 'aspartame'),
        // 중립 성분 — 룰 매칭이 없어 canonical key 가 없다.
        ReportedIngredient(text: '정제수'),
      ],
    );

    expect(ok, isTrue);
    expect(seenFn, 'report_data_error');
    expect(seenParams!['p_barcode'], '8809990172030');
    expect(seenParams!['p_reason'], 'ingredients_mismatch');
    expect(seenParams!['p_ingredients'], [
      {'text': '아스파탐', 'key': 'aspartame'},
      {'text': '정제수'},
    ]);
  });

  test('reportDataError defaults to an empty ingredient list', () async {
    Map<String, dynamic>? seenParams;
    final repo = ProductRepository.forTesting(
      rpc: (_, {params}) async {
        seenParams = params;
        return null;
      },
    );

    final ok = await repo.reportDataError(
      barcode: '8809990172030',
      reason: ReportReason.wrongProduct,
    );

    expect(ok, isTrue);
    expect(seenParams!['p_ingredients'], isEmpty);
  });

  test('reportDataError caps ingredients at the DB CHECK limit', () async {
    Map<String, dynamic>? seenParams;
    final repo = ProductRepository.forTesting(
      rpc: (_, {params}) async {
        seenParams = params;
        return null;
      },
    );

    await repo.reportDataError(
      barcode: '8809990172030',
      reason: ReportReason.ingredientsMismatch,
      ingredients: [
        for (var i = 0; i < 60; i++) ReportedIngredient(text: '성분$i'),
      ],
    );

    expect((seenParams!['p_ingredients'] as List).length, 50);
  });

  test('reportDataError truncates over-long ingredient text', () async {
    Map<String, dynamic>? seenParams;
    final repo = ProductRepository.forTesting(
      rpc: (_, {params}) async {
        seenParams = params;
        return null;
      },
    );

    // 쉼표 없는 라벨은 성분 조각 하나가 라벨 전체가 된다 — 0023 의 200자
    // 상한을 넘기면 서버가 거절하므로 앱이 먼저 자른다.
    await repo.reportDataError(
      barcode: '8809990172030',
      reason: ReportReason.ingredientsMismatch,
      ingredients: [
        ReportedIngredient(text: '가' * 500, canonicalKey: 'aspartame'),
        const ReportedIngredient(text: '정제수'),
      ],
    );

    final sent = (seenParams!['p_ingredients'] as List)
        .cast<Map<String, dynamic>>();
    expect(sent[0]['text'], hasLength(200));
    expect(sent[0]['text'], endsWith('…'));
    // 잘려도 key 는 남아야 한다 — 운영자가 성분을 특정하는 수단이다.
    expect(sent[0]['key'], 'aspartame');
    // 상한 이내는 손대지 않는다.
    expect(sent[1]['text'], '정제수');
  });

  test('reportDataError returns false when the RPC fails', () async {
    final repo = ProductRepository.forTesting(
      rpc: (_, {params}) async => throw const SocketException('offline'),
    );

    final ok = await repo.reportDataError(
      barcode: '8809990172030',
      reason: ReportReason.other,
    );

    expect(ok, isFalse);
  });

  test('reportDataError returns false when the RPC times out', () async {
    final repo = ProductRepository.forTesting(
      rpc: (_, {params}) => Future.delayed(
        const Duration(milliseconds: 50),
        () => null,
      ),
      timeout: const Duration(milliseconds: 5),
    );

    final ok = await repo.reportDataError(
      barcode: '8809990172030',
      reason: ReportReason.other,
    );

    expect(ok, isFalse);
  });
}
