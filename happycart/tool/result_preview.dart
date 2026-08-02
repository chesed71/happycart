// 개발용 프리뷰 진입점 — 바코드 스캔 없이 결과(result) 화면을 실기기에 바로
// 띄워 스크린샷을 뽑기 위한 임시 엔트리포인트다. 앱 흐름(main.dart)과는 분리돼
// 있으며 Supabase/Firebase 초기화 없이 ResultPage 만 렌더링한다.
//
// 실행:
//   flutter run -t tool/result_preview.dart --flavor development \
//     --dart-define=FLAVOR=development -d <device>
import 'package:flutter/material.dart';
import 'package:happycart/app/theme.dart';
import 'package:happycart/data/models/product_lookup_result.dart';
import 'package:happycart/features/result/result_page.dart';
import 'package:happycart/features/result/result_state.dart';
import 'package:happycart_rules/happycart_rules.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // ?tier=low|medium|high 쿼리로 대표 위험도별 성분 세트를 선택(프리뷰 3단계 확인용).
  // carrageenan=낮음, sugar·aspartame=보통, hydrogenated=높음.
  const setsByTier = {
    'low': ['carrageenan'],
    'medium': ['sugar', 'aspartame'],
    'high': ['sugar', 'carrageenan', 'hydrogenated', 'aspartame'],
  };
  // 전체 성분표(바텀시트) 미리보기용 라벨 원문 — bad 토큰 + 중립 성분 혼합.
  const rawByTier = {
    'low': '정제수, 카라기난, 밀가루(밀:미국산), 정제소금, 포도당, 향료',
    'medium': '정제수, 백설탕, 아스파탐, 밀가루(밀:미국산), 정제소금, 포도당',
    'high':
        '정제수, 백설탕, 아스파탐, 카라기난, 경화유(팜), 밀가루(밀:미국산), 정제소금, 포도당, 향료',
  };
  final tier = Uri.base.queryParameters['tier'] ?? 'high';
  final bad = setsByTier[tier] ?? setsByTier['high']!;
  final raw = rawByTier[tier] ?? rawByTier['high']!;

  final product = ProductLookupResult(
    barcode: '8809990172030',
    brand: '웰코리아',
    name: '사이다볼',
    size: '9g',
    category: '캔디류',
    imageUrl: null,
    ingredientsRaw: raw,
    verdict: Verdict.notOkay,
    badIngredients: bad,
    reasonCodes: const [],
    ruleVersion: 'v1.1.0',
    computedAt: DateTime.parse('2026-05-26T03:23:24Z'),
    sourceCheckedAt: DateTime.parse('2026-05-26T03:18:11.482068+00:00'),
  );

  runApp(
    MaterialApp(
      title: '해피카트',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.applyFontTo(AppTheme.warm()),
      home: ResultPage(
        state: ResultState.success(product),
        onRescan: () {},
      ),
    ),
  );
}
