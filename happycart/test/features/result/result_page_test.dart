import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:happycart/data/models/product_lookup_result.dart';
import 'package:happycart/features/result/result_page.dart';
import 'package:happycart/features/result/result_state.dart';
import 'package:happycart_rules/happycart_rules.dart';

ProductLookupResult _product({
  String? imageUrl,
  List<String> badIngredients = const ['blue_1', 'sugar'],
  List<String> reasonCodes = const ['artificial_color', 'refined_sugar'],
}) => ProductLookupResult(
  barcode: '8809990172030',
  brand: '웰코리아',
  name: '사이다볼',
  size: '9g',
  category: '캔디류',
  imageUrl: imageUrl,
  verdict: Verdict.notOkay,
  badIngredients: badIngredients,
  reasonCodes: reasonCodes,
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

  // FlagCard 헤더의 성분명 Text(fontSize 15) 만 골라 찾는다 — reasonCodeLabel
  // 태그와 canonicalLabel 이 우연히 같은 문자열(예: 카라기난)일 수 있어
  // find.text 만으로는 모호해질 수 있다.
  Finder cardName(String label) => find.byWidgetPredicate(
    (w) => w is Text && w.data == label && w.style?.fontSize == 15,
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

  testWidgets('황색 canonical label: yellow_5→황색4호, yellow_6→황색5호 (KR 번호 교정)', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ResultPage(
          state: ResultState.success(
            _product(
              badIngredients: const ['yellow_5', 'yellow_6'],
              reasonCodes: const ['artificial_color'],
            ),
          ),
          onRescan: () {},
        ),
      ),
    );

    expect(find.text('황색4호'), findsOneWidget); // yellow_5 = 타트라진
    expect(find.text('황색5호'), findsOneWidget); // yellow_6 = 선셋
    expect(find.text('황색6호'), findsNothing); // 옛 오류 라벨 제거
  });

  group('위험도 정렬 + 배지 + 컬러바', () {
    testWidgets(
      '카드가 위험도 내림차순으로 배치되고, 동순위는 canonicalKey 오름차순(tie-break), 미등록 key는 스킵',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: ResultPage(
              state: ResultState.success(
                _product(
                  // 입력 순서를 일부러 뒤섞는다 — 'sugar' 를 'aspartame' 보다
                  // 앞에 둬 tie-break 를 검증(§10 a2): 둘 다 riskLevel=medium
                  // 이므로 렌더 순서는 입력 순서가 아니라 canonicalKey 순이어야
                  // 한다(aspartame < sugar). 'nonexistent_key' 는 번들
                  // 카탈로그 미등록이라 스킵돼야 한다.
                  badIngredients: const [
                    'sugar',
                    'nonexistent_key',
                    'carrageenan',
                    'hydrogenated',
                    'aspartame',
                  ],
                  reasonCodes: const [],
                ),
              ),
              onRescan: () {},
            ),
          ),
        );

        // (c) 미등록 canonicalKey는 카드 자체가 안 생긴다 — 등록된 4건만.
        expect(find.byType(FlagCard), findsNWidgets(4));

        // (a)/(a2) 위험도 내림차순 + 동순위 canonicalKey 오름차순.
        final hydrogenatedY = tester
            .getTopLeft(cardName('경화유 / 트랜스지방'))
            .dy; // high
        final aspartameY = tester.getTopLeft(cardName('아스파탐')).dy; // medium
        final sugarY = tester.getTopLeft(cardName('설탕')).dy; // medium
        final carrageenanY = tester.getTopLeft(cardName('카라기난')).dy; // low

        expect(hydrogenatedY, lessThan(aspartameY));
        expect(aspartameY, lessThan(sugarY));
        expect(sugarY, lessThan(carrageenanY));

        // (b) 배지 텍스트 + 컬러바 렌더.
        expect(find.text('높음'), findsOneWidget);
        expect(find.text('보통'), findsNWidgets(2));
        expect(find.text('낮음'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('flagcard-risk-bar')),
          findsNWidgets(4),
        );
      },
    );

    testWidgets('FlagCard를 riskLevel: null로 pump하면 배지·컬러바 미표시(카드는 정상 렌더)', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FlagCard(
              name: '테스트 성분',
              tag: '테스트태그',
              reason: '테스트 사유',
              ruleCode: 'test_code',
              dotBg: const Color(0xFFFCE5E1),
              dotFg: const Color(0xFF9E2D22),
              riskLevel: null,
              riskReason: null,
              riskEvidence: null,
              isOpen: false,
              onToggle: () {},
            ),
          ),
        ),
      );

      expect(find.text('테스트 성분'), findsOneWidget);
      expect(find.text('높음'), findsNothing);
      expect(find.text('보통'), findsNothing);
      expect(find.text('낮음'), findsNothing);
      expect(find.byKey(const ValueKey('flagcard-risk-bar')), findsNothing);
    });
  });
}
