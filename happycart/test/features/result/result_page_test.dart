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

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.semanticLabel, '사이다볼');
  });

  testWidgets('success result falls back to cart icon without imageUrl', (
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

    expect(find.byIcon(Icons.shopping_cart_outlined), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });
}
