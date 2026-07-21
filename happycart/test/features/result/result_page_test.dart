import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:happycart/app/theme.dart';
import 'package:happycart/core/disclaimer_card.dart';
import 'package:happycart/data/models/product_lookup_result.dart';
import 'package:happycart/features/result/result_page.dart';
import 'package:happycart/features/result/result_state.dart';
import 'package:happycart_rules/happycart_rules.dart';

ProductLookupResult _product({
  String? imageUrl,
  List<String> badIngredients = const ['blue_1', 'sugar'],
  List<String> reasonCodes = const ['artificial_color', 'refined_sugar'],
  Verdict verdict = Verdict.notOkay,
}) => ProductLookupResult(
  barcode: '8809990172030',
  brand: '웰코리아',
  name: '사이다볼',
  size: '9g',
  category: '캔디류',
  imageUrl: imageUrl,
  verdict: verdict,
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

  // 카트 마크(Image.asset) 경로를 AssetImage 로 비교한다.
  Finder cartAssetImage(String path) => find.byWidgetPredicate(
    (w) =>
        w is Image &&
        w.image is AssetImage &&
        (w.image as AssetImage).assetName == path,
  );

  group('히어로 단계별 톤', () {
    testWidgets('높음(hydrogenated): 히어로 sub 미표시(배너와 중복돼 제거됨) + cart_stop 에셋', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ResultPage(
            state: ResultState.success(
              _product(
                badIngredients: const ['hydrogenated'],
                reasonCodes: const [],
              ),
            ),
            onRescan: () {},
          ),
        ),
      );

      expect(find.text('소량도 위험할 수 있어요. 담지 않는 걸 권해요.'), findsNothing);
      expect(cartAssetImage('assets/verdict/cart_stop.png'), findsOneWidget);
    });

    testWidgets('중간(sugar): 히어로 sub 미표시(배너와 중복돼 제거됨) + cart_med 에셋', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ResultPage(
            state: ResultState.success(
              _product(badIngredients: const ['sugar'], reasonCodes: const []),
            ),
            onRescan: () {},
          ),
        ),
      );

      expect(find.text('양에 따라 괜찮을 수도, 아닐 수도 있어요. 적당히 드세요.'), findsNothing);
      expect(cartAssetImage('assets/verdict/cart_med.png'), findsOneWidget);
    });

    testWidgets('낮음(carrageenan): 히어로 sub 미표시(배너와 중복돼 제거됨) + cart_low 에셋', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ResultPage(
            state: ResultState.success(
              _product(
                badIngredients: const ['carrageenan'],
                reasonCodes: const [],
              ),
            ),
            onRescan: () {},
          ),
        ),
      );

      expect(find.text('특정 조건에서만 신경 쓰면 되는 성분이 있어요.'), findsNothing);
      expect(cartAssetImage('assets/verdict/cart_low.png'), findsOneWidget);
    });
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

  group('태그 중복 숨김', () {
    testWidgets('carrageenan: name과 tag가 같으면 태그 배지가 중복 표시되지 않는다', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ResultPage(
            state: ResultState.success(
              _product(
                badIngredients: const ['carrageenan'],
                reasonCodes: const [],
              ),
            ),
            onRescan: () {},
          ),
        ),
      );

      // canonicalLabel('carrageenan')과 reasonCodeLabel('carrageenan') 모두
      // '카라기난' 이라 태그 배지를 표시하면 헤더에 문구가 중복된다 — 배지는
      // 숨기고 성분명 텍스트만 남아야 한다.
      expect(find.text('카라기난'), findsOneWidget);
    });

    testWidgets('설탕: name과 tag가 다르면 태그 배지가 그대로 표시된다', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ResultPage(
            state: ResultState.success(
              _product(badIngredients: const ['sugar'], reasonCodes: const []),
            ),
            onRescan: () {},
          ),
        ),
      );

      expect(find.text('설탕'), findsOneWidget); // 성분명
      expect(find.text('정제 설탕'), findsOneWidget); // 태그 배지(reasonCodeLabel)
    });
  });

  group('펼침 영역 건강 근거 병기', () {
    testWidgets(
      '펼친 카드에 reason 은 유지되고 RULE 은 표시되지 않으며 그 아래 건강 근거·출처가 병기된다(실 카탈로그: hydrogenated)',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: ResultPage(
              state: ResultState.success(
                _product(
                  // hydrogenated 는 riskLevel.high 라 정렬 최상위 → 첫 카드
                  // (자동 펼침)가 된다.
                  badIngredients: const ['hydrogenated'],
                  reasonCodes: const [],
                ),
              ),
              onRescan: () {},
            ),
          ),
        );

        // (a) 기존 reason 표시가 대체되지 않고 여전히 남아 있다. RULE 줄은
        // 개발용이라 화면에서 제거됐다.
        expect(find.text('경화 처리 과정에서 트랜스지방이 생성될 수 있어요.'), findsOneWidget);
        expect(find.text('RULE: hydrogenated_oil'), findsNothing);

        // (b) 그 아래 건강 근거·출처가 병기된다 — badIngredientCatalog의
        // hydrogenated 엔트리 실값. 라벨("건강 근거"/"출처")은 제거되고
        // reason·건강 근거는 각각 '•' 불릿 + 순수 본문으로, 출처는
        // '출처: ' 접두 한 줄로 병기된다.
        expect(find.text('건강 근거'), findsNothing);
        expect(
          find.text('심혈관 질환 위험을 높이며 LDL(나쁜 콜레스테롤)을 올리고 HDL(좋은 콜레스테롤)을 낮춥니다.'),
          findsOneWidget,
        );
        expect(
          find.text('* 심혈관 질환 위험을 높이며 LDL(나쁜 콜레스테롤)을 올리고 HDL(좋은 콜레스테롤)을 낮춥니다.'),
          findsNothing,
        );
        // 펼쳐진 카드는 이 한 장뿐이라 불릿(•)은 reason·건강 근거 2개.
        expect(find.text('•'), findsNWidgets(2));
        expect(find.text('출처'), findsNothing);
        expect(find.text('출처: WHO REPLACE; FDA PHO; AHA'), findsOneWidget);
      },
    );

    testWidgets('FlagCard: riskEvidence가 빈/null이면 출처 줄만 생략되고 카드는 정상 렌더', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FlagCard(
              name: '테스트 성분',
              tag: '테스트태그',
              reason: '테스트 사유',
              dotBg: const Color(0xFFFCE5E1),
              dotFg: const Color(0xFF9E2D22),
              riskLevel: RiskLevel.medium,
              riskReason: '테스트 위험 사유',
              riskEvidence: '   ', // 공백뿐 — null과 동일하게 취급돼야 함
              isOpen: true,
              onToggle: () {},
            ),
          ),
        ),
      );

      expect(find.text('테스트 성분'), findsOneWidget);
      expect(find.text('테스트 사유'), findsOneWidget);
      expect(find.text('건강 근거'), findsNothing);
      expect(find.text('테스트 위험 사유'), findsOneWidget);
      expect(find.text('* 테스트 위험 사유'), findsNothing);
      // reason·건강 근거 각각 불릿(•), 출처는 빈 값이라 생략(불릿 없음).
      expect(find.text('•'), findsNWidgets(2));
      expect(find.textContaining('출처'), findsNothing);
    });

    testWidgets('FlagCard: riskReason이 null이면 건강 근거 줄만 생략되고 카드는 정상 렌더', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FlagCard(
              name: '테스트 성분',
              tag: '테스트태그',
              reason: '테스트 사유',
              dotBg: const Color(0xFFFCE5E1),
              dotFg: const Color(0xFF9E2D22),
              riskLevel: RiskLevel.medium,
              riskReason: null,
              riskEvidence: 'WHO',
              isOpen: true,
              onToggle: () {},
            ),
          ),
        ),
      );

      expect(find.text('테스트 성분'), findsOneWidget);
      expect(find.text('테스트 사유'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is Text && (w.data?.startsWith('* ') ?? false),
        ),
        findsNothing,
      );
      // riskReason이 없으니 불릿(•)은 reason 것 하나만.
      expect(find.text('•'), findsOneWidget);
      expect(find.text('출처'), findsNothing);
      expect(find.text('출처: WHO'), findsOneWidget);
    });
  });

  group('위험도 게이지', () {
    // 3칸 막대는 전부 같은 ValueKey 를 쓰므로, 렌더 순서대로 색을 비교한다.
    Finder gaugeBars() => find.byKey(const ValueKey('risk-gauge-bar'));
    Color barColor(WidgetTester tester, int index) {
      final container = tester.widgetList<Container>(gaugeBars()).elementAt(index);
      return (container.decoration! as BoxDecoration).color!;
    }

    // "위험도 <라벨>" 전체 문구를 Text.rich 의 최종 렌더 텍스트로 검증한다 —
    // FlagCard 위험도 배지(높음/보통/낮음)와 문자열이 겹칠 수 있어 plain
    // find.text 대신 전체 문구 일치로 모호성을 없앤다.
    Finder gaugeFullText(String text) => find.byWidgetPredicate(
      (w) => w is Text && w.textSpan?.toPlainText() == text,
    );

    testWidgets('높음(hydrogenated): 게이지 3칸 채움 + "위험도 높음"', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ResultPage(
            state: ResultState.success(
              _product(
                badIngredients: const ['hydrogenated'],
                reasonCodes: const [],
              ),
            ),
            onRescan: () {},
          ),
        ),
      );

      expect(gaugeBars(), findsNWidgets(3));
      expect(barColor(tester, 0), AppTheme.stopMain);
      expect(barColor(tester, 1), AppTheme.stopMain);
      expect(barColor(tester, 2), AppTheme.stopMain);
      expect(gaugeFullText('위험도 높음'), findsOneWidget);
    });

    testWidgets('중간(sugar): 게이지 2칸 채움 + "위험도 중간"', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ResultPage(
            state: ResultState.success(
              _product(badIngredients: const ['sugar'], reasonCodes: const []),
            ),
            onRescan: () {},
          ),
        ),
      );

      expect(gaugeBars(), findsNWidgets(3));
      expect(barColor(tester, 0), AppTheme.medMain);
      expect(barColor(tester, 1), AppTheme.medMain);
      expect(barColor(tester, 2), AppTheme.gaugeEmpty);
      expect(gaugeFullText('위험도 중간'), findsOneWidget);
    });

    testWidgets('낮음(carrageenan): 게이지 1칸 채움 + "위험도 낮음"', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ResultPage(
            state: ResultState.success(
              _product(
                badIngredients: const ['carrageenan'],
                reasonCodes: const [],
              ),
            ),
            onRescan: () {},
          ),
        ),
      );

      expect(gaugeBars(), findsNWidgets(3));
      expect(barColor(tester, 0), AppTheme.lowMain);
      expect(barColor(tester, 1), AppTheme.gaugeEmpty);
      expect(barColor(tester, 2), AppTheme.gaugeEmpty);
      expect(gaugeFullText('위험도 낮음'), findsOneWidget);
    });

    testWidgets('okay: 게이지가 렌더되지 않는다', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ResultPage(
            state: ResultState.success(
              _product(
                badIngredients: const [],
                reasonCodes: const [],
                verdict: Verdict.okay,
              ),
            ),
            onRescan: () {},
          ),
        ),
      );

      expect(find.byType(RiskMeter), findsNothing);
      expect(gaugeBars(), findsNothing);
    });

    testWidgets('RiskMeter 직접 pump: filled 개수만큼 fillColor, 나머지는 emptyColor', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: RiskMeter(
              filled: 2,
              label: '중간',
              fillColor: Color(0xFFEE7A1A),
              emptyColor: Color(0xFFE9DECB),
            ),
          ),
        ),
      );

      expect(gaugeBars(), findsNWidgets(3));
      expect(barColor(tester, 0), const Color(0xFFEE7A1A));
      expect(barColor(tester, 1), const Color(0xFFEE7A1A));
      expect(barColor(tester, 2), const Color(0xFFE9DECB));
      expect(gaugeFullText('위험도 중간'), findsOneWidget);
    });
  });

  group('안내 배너', () {
    testWidgets('중간(sugar): 안내 배너 문구가 성분 헤더보다 위에 보인다', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ResultPage(
            state: ResultState.success(
              _product(badIngredients: const ['sugar'], reasonCodes: const []),
            ),
            onRescan: () {},
          ),
        ),
      );

      const bannerText = '용량 의존형 위험이에요. 가끔·적당량이면 괜찮지만, 자주·많이 드시는 건 피하세요.';
      expect(find.text(bannerText), findsOneWidget);

      final bannerY = tester.getTopLeft(find.text(bannerText)).dy;
      final headerY = tester.getTopLeft(find.text('신경 쓰이는 성분')).dy;
      expect(bannerY, lessThan(headerY));
    });

    testWidgets('높음(hydrogenated): 안내 배너 문구가 성분 헤더보다 위에 보인다', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ResultPage(
            state: ResultState.success(
              _product(
                badIngredients: const ['hydrogenated'],
                reasonCodes: const [],
              ),
            ),
            onRescan: () {},
          ),
        ),
      );

      const bannerText = '높은 위험이에요. 안전한 섭취 구간이 없어, 되도록 피하는 걸 권해요.';
      expect(find.text(bannerText), findsOneWidget);

      final bannerY = tester.getTopLeft(find.text(bannerText)).dy;
      final headerY = tester.getTopLeft(find.text('신경 쓰이는 성분')).dy;
      expect(bannerY, lessThan(headerY));
    });

    testWidgets('okay: 안내 배너가 렌더되지 않는다', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ResultPage(
            state: ResultState.success(
              _product(
                badIngredients: const [],
                reasonCodes: const [],
                verdict: Verdict.okay,
              ),
            ),
            onRescan: () {},
          ),
        ),
      );

      expect(find.byType(RiskNoteBanner), findsNothing);
    });
  });

  group('통합 시나리오', () {
    testWidgets(
      '높음 대표 제품: 게이지 3칸·배너·성분 카드 4장·첫 카드 펼침이 동시에 high 로 일관 렌더',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: ResultPage(
              state: ResultState.success(
                _product(
                  badIngredients: const [
                    'sugar',
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

        // 히어로: sub 문구는 배너와 중복돼 제거됐다.
        expect(find.text('소량도 위험할 수 있어요. 담지 않는 걸 권해요.'), findsNothing);

        // 게이지: 3칸 채움 + "위험도 높음".
        final gaugeBars = find.byKey(const ValueKey('risk-gauge-bar'));
        expect(gaugeBars, findsNWidgets(3));
        Color barColor(int index) {
          final container = tester
              .widgetList<Container>(gaugeBars)
              .elementAt(index);
          return (container.decoration! as BoxDecoration).color!;
        }

        expect(barColor(0), AppTheme.stopMain);
        expect(barColor(1), AppTheme.stopMain);
        expect(barColor(2), AppTheme.stopMain);
        expect(
          find.byWidgetPredicate(
            (w) => w is Text && w.textSpan?.toPlainText() == '위험도 높음',
          ),
          findsOneWidget,
        );

        // 안내 배너: 높음 문구.
        expect(
          find.text('높은 위험이에요. 안전한 섭취 구간이 없어, 되도록 피하는 걸 권해요.'),
          findsOneWidget,
        );

        // 성분 카드 4장, 위험도 내림차순(hydrogenated high > aspartame/sugar
        // medium(canonicalKey 오름차순) > carrageenan low).
        expect(find.byType(FlagCard), findsNWidgets(4));
        final hydrogenatedY = tester.getTopLeft(cardName('경화유 / 트랜스지방')).dy;
        final aspartameY = tester.getTopLeft(cardName('아스파탐')).dy;
        final sugarY = tester.getTopLeft(cardName('설탕')).dy;
        final carrageenanY = tester.getTopLeft(cardName('카라기난')).dy;
        expect(hydrogenatedY, lessThan(aspartameY));
        expect(aspartameY, lessThan(sugarY));
        expect(sugarY, lessThan(carrageenanY));

        // 기존 성분 카드 요소 유지: 배지 + 컬러바.
        expect(find.text('높음'), findsOneWidget);
        expect(find.text('보통'), findsNWidgets(2));
        expect(find.text('낮음'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('flagcard-risk-bar')),
          findsNWidgets(4),
        );

        // 첫 카드(hydrogenated, high) 자동 펼침 — 건강 근거·출처 유지, RULE은 미표시.
        // 라벨은 제거되고 reason·건강 근거는 '•' 불릿 + 순수 본문, 출처는
        // '출처: ' 접두 한 줄.
        expect(find.text('경화 처리 과정에서 트랜스지방이 생성될 수 있어요.'), findsOneWidget);
        expect(find.text('RULE: hydrogenated_oil'), findsNothing);
        expect(find.text('건강 근거'), findsNothing);
        expect(
          find.text('심혈관 질환 위험을 높이며 LDL(나쁜 콜레스테롤)을 올리고 HDL(좋은 콜레스테롤)을 낮춥니다.'),
          findsOneWidget,
        );
        // 이 시나리오도 펼쳐진 카드는 첫 카드 하나뿐 — 불릿(•) 2개(reason+건강 근거).
        expect(find.text('•'), findsNWidgets(2));
        expect(find.text('출처'), findsNothing);
        expect(find.text('출처: WHO REPLACE; FDA PHO; AHA'), findsOneWidget);
      },
    );

    testWidgets('okay 회귀: 초록 히어로만 렌더되고 게이지·배너·성분 카드는 없다', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ResultPage(
            state: ResultState.success(
              _product(
                badIngredients: const [],
                reasonCodes: const [],
                verdict: Verdict.okay,
              ),
            ),
            onRescan: () {},
          ),
        ),
      );

      expect(find.text('괜찮아요'), findsOneWidget);
      expect(find.byType(RiskMeter), findsNothing);
      expect(find.byType(RiskNoteBanner), findsNothing);
      expect(find.byType(FlagCard), findsNothing);
    });

    testWidgets('not_okay: 하단 안내 문구는 제거되고 DisclaimerCard는 그대로 렌더된다', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ResultPage(state: ResultState.success(_product()), onRescan: () {}),
        ),
      );

      expect(find.textContaining('성분 이름 기준으로'), findsNothing);
      expect(find.byType(DisclaimerCard), findsOneWidget);
    });
  });

  group('좁은 화면(360dp) 섹션 헤더 오버플로', () {
    // 이 그룹만 좁은 폭(360x800)으로 뷰포트를 덮어쓴다 — 바깥 setUp(1080x2400)과
    // 간섭하지 않도록 그룹 전용 setUp/tearDown으로 격리한다.
    setUp(() {
      final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
      view.physicalSize = const Size(360, 800);
      view.devicePixelRatio = 1.0;
    });
    tearDown(() {
      final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });

    testWidgets('높음(hydrogenated) 자동 펼침 카드의 "신경 쓰이는 성분" 헤더가 hint와 함께 가로 오버플로하지 않는다', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ResultPage(
            state: ResultState.success(
              _product(
                badIngredients: const ['hydrogenated'],
                reasonCodes: const [],
              ),
            ),
            onRescan: () {},
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });
  });
}
