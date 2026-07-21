import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/verdict.dart';

/// HappyCart 디자인 토큰 (스펙 §6.3) 과 앱 [ThemeData] 팩토리.
///
/// 메인 브랜드 컬러는 아이콘의 오렌지(#FF7A1A). verdict 컬러는 okay=그린,
/// notOkay=레드. Pretendard 는 google_fonts 카탈로그에
/// 없어 Noto Sans KR 로 대체한다. 로컬 번들링은 후속 작업.
class AppTheme {
  AppTheme._();

  // === Surface / Ink ===
  static const Color bg = Color(0xFFFFFAF5);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceAlt = Color(0xFFFFF1E0);
  static const Color ink = Color(0xFF1F1B16);
  static const Color inkSoft = Color(0xFF5C544A);
  static const Color inkMute = Color(0xFF9B9388);
  static const Color line = Color(0xFFF0E2CF);

  // === Brand (orange) ===
  static const Color brand = Color(0xFFFF7A1A);
  static const Color brandStrong = Color(0xFFE85F00);
  static const Color brandSoft = Color(0xFFFFE6CC);

  // === Verdict (chip/badge 단색용) ===
  static const Color okay = Color(0xFF2E8B57);
  static const Color okayBg = Color(0xFFE0F2E5);
  static const Color notOkay = Color(0xFFD04437);
  static const Color notOkayBg = Color(0xFFFBE3DF);

  // === Verdict 히어로 그라디언트 토큰 ===
  static const Color okDeep = Color(0xFF10764A);
  static const Color okGradA = Color(0xFF1FA869);
  static const Color okGradB = Color(0xFF15875A);
  static const Color okSoft = Color(0xFFE4F4EA);

  static const Color stopDeep = Color(0xFF9E2D22);
  static const Color stopMain = Color(0xFFE14A39);
  static const Color stopSoft = Color(0xFFFCE5E1);
  static const Color stopGradA = Color(0xFFEF5A45);
  static const Color stopGradB = Color(0xFFD23A2C);

  // === 대표 위험도 단계 (낮음/중간) 팔레트 — 높음은 stop 계열 재사용 ===
  static const Color lowMain = Color(0xFFE1A50B);
  static const Color lowDeep = Color(0xFF8A6300);
  static const Color lowSoft = Color(0xFFFBEFC9);

  static const Color medMain = Color(0xFFEE7A1A);
  static const Color medDeep = Color(0xFFA85400);
  static const Color medSoft = Color(0xFFFCE7D0);

  // === 위험도 히어로 배경 상단색 (하단은 공통 Color(0xFFFCFBF8)) ===
  static const Color heroBgLow = Color(0xFFFBF1CF);
  static const Color heroBgMed = Color(0xFFFCE8D2);
  static const Color heroBgHigh = Color(0xFFFCE3DE);

  // === 위험도 게이지 빈칸 ===
  static const Color gaugeEmpty = Color(0xFFE9DECB);

  static Color colorFor(Verdict v) {
    switch (v) {
      case Verdict.okay:
        return okay;
      case Verdict.notOkay:
        return notOkay;
    }
  }

  static Color bgColorFor(Verdict v) {
    switch (v) {
      case Verdict.okay:
        return okayBg;
      case Verdict.notOkay:
        return notOkayBg;
    }
  }

  static ThemeData warm() {
    final base = ColorScheme.fromSeed(
      seedColor: brand,
      brightness: Brightness.light,
    );
    final colorScheme = base.copyWith(
      primary: brand,
      onPrimary: Colors.white,
      secondary: okay,
      onSecondary: Colors.white,
      surface: surface,
      onSurface: ink,
      surfaceContainerHighest: surfaceAlt,
      outline: line,
      outlineVariant: line,
      error: notOkay,
      onError: Colors.white,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: bg,
      dividerColor: line,
    );
  }

  /// Wraps [base] with the Noto Sans KR text theme. Call from a widget build
  /// method so font loading happens inside a live binding.
  static ThemeData applyFontTo(ThemeData base) {
    return base.copyWith(
      textTheme: GoogleFonts.notoSansKrTextTheme(base.textTheme),
    );
  }
}
