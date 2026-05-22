import 'package:flutter/material.dart';

import '../features/result/result_page.dart';
import '../features/result/result_state.dart';
import '../features/scan/scan_screen.dart';
import 'theme.dart';

/// 앱 루트 위젯 (스펙 §6).
///
/// 워밍 팔레트 [AppTheme.warm] 를 깔고 Noto Sans KR 텍스트 테마를
/// [AppTheme.applyFontTo] 로 적용한다 (Task 3 코드 리뷰 반영).
/// 진입 화면은 [ScanScreen] — 결과 화면은 [pushResult] 헬퍼로 push 한다.
class HappyCartApp extends StatelessWidget {
  const HappyCartApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '해피카트',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.applyFontTo(AppTheme.warm()),
      home: const ScanScreen(),
    );
  }
}

/// [ResultPage] 를 push 하는 헬퍼.
///
/// 호출 측 (ScanScreen) 은 `await pushResult(...)` 로 결과 화면이 pop 될
/// 때까지 기다린 뒤 스캐너를 재개한다. ResultPage 내부의 "다시 스캔하기"
/// 버튼은 단순히 [Navigator.maybePop] 만 호출하면 된다.
Future<void> pushResult(BuildContext context, ResultState state) {
  final navigator = Navigator.of(context);
  return navigator.push(
    MaterialPageRoute<void>(
      builder: (_) => ResultPage(
        state: state,
        onRescan: () => navigator.maybePop(),
      ),
    ),
  );
}
