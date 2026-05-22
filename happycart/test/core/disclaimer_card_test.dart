import 'package:happycart/app/theme.dart';
import 'package:happycart/core/disclaimer_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DisclaimerCard', () {
    testWidgets('renders exact spec §12 disclaimer text', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: DisclaimerCard())),
      );
      expect(
        find.text(
          '참고 정보입니다. 알레르기·질환·임신·영유아 식이는 제품 표시와 전문가 판단을 우선해주세요.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('has no close button (cannot be dismissed)', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: DisclaimerCard())),
      );
      expect(find.byType(IconButton), findsNothing);
      expect(find.byType(CloseButton), findsNothing);
      expect(find.byIcon(Icons.close), findsNothing);
    });

    testWidgets('shows info icon as leading indicator', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: DisclaimerCard())),
      );
      expect(find.byIcon(Icons.info_outline), findsOneWidget);
    });

    testWidgets('uses surfaceAlt background color', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: DisclaimerCard())),
      );
      final container = tester.widget<Container>(
        find.byType(Container).first,
      );
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.color, AppTheme.surfaceAlt);
    });
  });
}
