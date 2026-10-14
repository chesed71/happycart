import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:happycart/data/models/product_lookup_result.dart';
import 'package:happycart/data/product_repository.dart';
import 'package:happycart/features/result/result_page.dart';
import 'package:happycart/features/result/result_state.dart';
import 'package:happycart_rules/happycart_rules.dart';

ProductLookupResult _product({
  String ingredientsRaw = '정제수, 아스파탐, 밀가루',
  List<String> badIngredients = const ['aspartame'],
  Verdict verdict = Verdict.notOkay,
}) => ProductLookupResult(
  barcode: '8809990172030',
  brand: '웰코리아',
  name: '사이다볼',
  size: '9g',
  category: '캔디류',
  imageUrl: null,
  ingredientsRaw: ingredientsRaw,
  verdict: verdict,
  badIngredients: badIngredients,
  reasonCodes: const [],
  ruleVersion: 'v1.1.0',
  computedAt: DateTime.parse('2026-05-26T03:23:24Z'),
  sourceCheckedAt: DateTime.parse('2026-05-26T03:18:11.482068+00:00'),
);

/// 호출된 RPC 파라미터를 받아두는 기록장.
class _RpcLog {
  final calls = <Map<String, dynamic>>[];
  bool succeed = true;

  Future<dynamic> call(String fn, {Map<String, dynamic>? params}) async {
    calls.add({'fn': fn, ...?params});
    if (!succeed) throw StateError('offline');
    return null;
  }
}

/// 지목 단계의 성분 알약(fontSize 14)만 집는다 — 뒤에 깔린 FlagCard 헤더가
/// 같은 성분명을 fontSize 15 로 그리고 있어 find.text 로는 모호하다.
Finder pickPill(String label) => find.byWidgetPredicate(
  (w) => w is Text && w.data == label && w.style?.fontSize == 14,
);

void main() {
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

  Future<_RpcLog> pumpResult(
    WidgetTester tester,
    ResultState state, {
    bool succeed = true,
  }) async {
    final log = _RpcLog()..succeed = succeed;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productRepositoryProvider.overrideWithValue(
            ProductRepository.forTesting(rpc: log.call),
          ),
        ],
        child: MaterialApp(
          home: ResultPage(state: state, onRescan: () {}),
        ),
      ),
    );
    return log;
  }

  group('상단 오류 신고 알약', () {
    testWidgets('탭하면 신고 시트가 열리고 잠깐 경로 사유가 뜬다', (tester) async {
      await pumpResult(tester, ResultState.success(_product()));

      await tester.tap(find.text('오류 신고'));
      await tester.pumpAndSettle();

      expect(find.text('무엇이 다른가요?'), findsOneWidget);
      expect(find.text('성분표가 제품과 달라요'), findsOneWidget);
      expect(find.text('이 성분은 위험하지 않아요'), findsOneWidget);
      expect(find.text('다른 제품 정보예요'), findsOneWidget);
      expect(find.text('그 밖에 달라요'), findsOneWidget);
      // 괜찮아요 전용 사유는 나오면 안 된다.
      expect(find.text('빠진 주의 성분이 있어요'), findsNothing);
    });

    testWidgets('괜찮아요 경로는 빠진 주의 성분 사유를 보여준다', (tester) async {
      await pumpResult(
        tester,
        ResultState.success(
          _product(verdict: Verdict.okay, badIngredients: const []),
        ),
      );

      await tester.tap(find.text('오류 신고'));
      await tester.pumpAndSettle();

      expect(find.text('빠진 주의 성분이 있어요'), findsOneWidget);
      expect(find.text('이 성분은 위험하지 않아요'), findsNothing);
    });

    testWidgets('사유를 고르기 전에는 보내기가 비활성', (tester) async {
      await pumpResult(tester, ResultState.success(_product()));
      await tester.tap(find.text('오류 신고'));
      await tester.pumpAndSettle();

      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '보내기'),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('신고 전송', () {
    testWidgets('성분 지목이 없는 사유는 바로 전송된다', (tester) async {
      final log = await pumpResult(tester, ResultState.success(_product()));

      await tester.tap(find.text('오류 신고'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('다른 제품 정보예요'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('보내기'));
      await tester.pumpAndSettle();

      expect(log.calls, hasLength(1));
      expect(log.calls.single['fn'], 'report_data_error');
      expect(log.calls.single['p_reason'], 'wrong_product');
      expect(log.calls.single['p_barcode'], '8809990172030');
      expect(log.calls.single['p_ingredients'], isEmpty);
      // 시트는 닫히고 접수 안내가 뜬다.
      expect(find.text('무엇이 다른가요?'), findsNothing);
      expect(find.textContaining('접수됐어요'), findsOneWidget);
    });

    testWidgets('성분표 불일치는 성분 지목 단계를 거친다', (tester) async {
      final log = await pumpResult(tester, ResultState.success(_product()));

      await tester.tap(find.text('오류 신고'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('성분표가 제품과 달라요'));
      await tester.pumpAndSettle();

      // 지목할 성분이 있으면 보내기가 아니라 다음으로 넘어간다.
      expect(find.text('다음'), findsOneWidget);
      await tester.tap(find.text('다음'));
      await tester.pumpAndSettle();

      expect(find.text('어느 성분이 다른가요?'), findsOneWidget);
      await tester.tap(pickPill('아스파탐'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('보내기'));
      await tester.pumpAndSettle();

      expect(log.calls.single['p_reason'], 'ingredients_mismatch');
      expect(log.calls.single['p_ingredients'], [
        {'text': '아스파탐', 'key': 'aspartame'},
      ]);
    });

    testWidgets('중립 성분을 지목하면 canonical key 없이 원문만 보낸다', (tester) async {
      final log = await pumpResult(tester, ResultState.success(_product()));

      await tester.tap(find.text('오류 신고'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('성분표가 제품과 달라요'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('다음'));
      await tester.pumpAndSettle();
      await tester.tap(pickPill('정제수'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('보내기'));
      await tester.pumpAndSettle();

      expect(log.calls.single['p_ingredients'], [
        {'text': '정제수'},
      ]);
    });

    testWidgets('성분 원문이 없으면 지목 단계를 건너뛴다', (tester) async {
      final log = await pumpResult(
        tester,
        ResultState.success(_product(ingredientsRaw: '')),
      );

      await tester.tap(find.text('오류 신고'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('성분표가 제품과 달라요'));
      await tester.pumpAndSettle();

      expect(find.text('다음'), findsNothing);
      await tester.tap(find.text('보내기'));
      await tester.pumpAndSettle();

      expect(log.calls.single['p_ingredients'], isEmpty);
    });

    testWidgets('전송이 실패하면 시트를 닫지 않고 다시 시도를 안내한다', (tester) async {
      await pumpResult(
        tester,
        ResultState.success(_product()),
        succeed: false,
      );

      await tester.tap(find.text('오류 신고'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('그 밖에 달라요'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('보내기'));
      await tester.pumpAndSettle();

      expect(find.textContaining('지금은 보낼 수 없어요'), findsOneWidget);
      expect(find.text('다시 시도'), findsOneWidget);
      // 고른 사유가 남아 있어야 다시 누르기만 하면 된다.
      expect(find.text('무엇이 다른가요?'), findsOneWidget);
    });
  });

  testWidgets('전체 성분표 시트에서도 신고로 이어진다', (tester) async {
    await pumpResult(tester, ResultState.success(_product()));

    await tester.tap(find.text('전체 성분표 보기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('이 정보가 틀렸나요?'));
    await tester.pumpAndSettle();

    expect(find.text('전체 성분표'), findsNothing);
    expect(find.text('무엇이 다른가요?'), findsOneWidget);
  });

  group('미등록 제품 등록 요청', () {
    testWidgets('버튼을 누르면 register_request 로 전송된다', (tester) async {
      final log = await pumpResult(
        tester,
        ResultState.notFound('8809990172030'),
      );

      await tester.tap(find.text('이 제품 등록 요청하기'));
      await tester.pumpAndSettle();

      expect(log.calls.single['fn'], 'report_data_error');
      expect(log.calls.single['p_reason'], 'register_request');
      expect(log.calls.single['p_barcode'], '8809990172030');
      expect(find.text('등록을 요청했어요'), findsOneWidget);
    });

    testWidgets('실패하면 버튼이 그대로 남는다', (tester) async {
      await pumpResult(
        tester,
        ResultState.notFound('8809990172030'),
        succeed: false,
      );

      await tester.tap(find.text('이 제품 등록 요청하기'));
      await tester.pumpAndSettle();

      expect(find.text('등록을 요청했어요'), findsNothing);
      expect(find.text('이 제품 등록 요청하기'), findsOneWidget);
      expect(find.textContaining('지금은 보낼 수 없어요'), findsOneWidget);
    });
  });
}
