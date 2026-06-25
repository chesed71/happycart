import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:happycart/data/models/product_lookup_result.dart';
import 'package:happycart/features/result/result_page.dart';
import 'package:happycart/features/result/result_state.dart';
import 'package:happycart_rules/happycart_rules.dart';

ProductLookupResult _product({String? imageUrl}) => ProductLookupResult(
  barcode: '8809990172030',
  brand: '웰코리아',
  name: '사이다볼',
  size: '9g',
  category: '캔디류',
  imageUrl: imageUrl,
  verdict: Verdict.notOkay,
  badIngredients: const ['blue_1', 'sugar'],
  reasonCodes: const ['artificial_color', 'refined_sugar'],
  ruleVersion: 'v1.1.0',
  computedAt: DateTime.parse('2026-05-26T03:23:24Z'),
  sourceCheckedAt: DateTime.parse('2026-05-26T03:18:11.482068+00:00'),
);

void main() {
  // 히어로가 큰 화면이라 기본 800x600 테스트 표면에선 오버플로 — 실제 폰 크기로.
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1080, 2400);
    view.devicePixelRatio = 1.0;
  });
  tearDown(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  // 히어로 합성: 카트·손 마크(Image.asset) + 제품 이미지 슬롯. 제품 이미지는
  // semanticLabel(제품명)로 식별한다.
  Finder productImage() => find.byWidgetPredicate(
    (w) => w is Image && w.semanticLabel == '사이다볼',
  );

  testWidgets('success result renders product image when imageUrl is present', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ResultPage(
          state: ResultState.success(
            _product(imageUrl: 'https://thumbnail.coupangcdn.com/product.jpg'),
          ),
          onRescan: () {},
        ),
      ),
    );

    expect(productImage(), findsOneWidget);
  });

  testWidgets('success result falls back to placeholder icon without imageUrl', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ResultPage(
          state: ResultState.success(_product()),
          onRescan: () {},
        ),
      ),
    );

    // 제품 이미지(network)는 없고, 슬롯에 fallback 아이콘이 뜬다.
    expect(productImage(), findsNothing);
    expect(find.byIcon(Icons.shopping_bag_outlined), findsOneWidget);
  });
}
