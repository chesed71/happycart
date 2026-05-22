import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/verdict.dart';

/// HappyCart 디자인 토큰 (스펙 §6.3) 과 앱 [ThemeData] 팩토리.
///
/// 메인 브랜드 컬러는 아이콘의 오렌지(#FF7A1A). verdict 컬러는 okay=그린,
/// notOkay=레드, insufficient=뉴트럴 그레이. Pretendard 는 google_fonts 카탈로그에
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

  // === Verdict ===
  static const Color okay = Color(0xFF2E8B57);
  static const Color okayBg = Color(0xFFE0F2E5);
  static const Color notOkay = Color(0xFFD04437);
  static const Color notOkayBg = Color(0xFFFBE3DF);
  static const Color insufficient = Color(0xFF6B6660);
  static const Color insufficientBg = Color(0xFFEEE9E0);

  static Color colorFor(Verdict v) {
    switch (v) {
      case Verdict.okay:
        return okay;
      case Verdict.notOkay:
        return notOkay;
      case Verdict.insufficient:
        return insufficient;
    }
  }

  static Color bgColorFor(Verdict v) {
    switch (v) {
      case Verdict.okay:
        return okayBg;
      case Verdict.notOkay:
        return notOkayBg;
      case Verdict.insufficient:
        return insufficientBg;
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
