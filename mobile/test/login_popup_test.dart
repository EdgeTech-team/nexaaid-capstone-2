import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/login_screen.dart';

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  Widget host() => MaterialApp(
    theme: AppTheme.light(),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => showLoginPopup(context),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );

  testWidgets('Log in opens as a blurred pop-up and closes with X',
      (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.text('Forgot password?'), findsOneWidget);
    expect(find.text('Back'), findsNothing); // the pop-up uses X instead

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Forgot password?'), findsNothing);
    expect(find.text('Open'), findsOneWidget);
  });

  testWidgets('Tapping outside the card closes it', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(5, 5)); // the blurred background
    await tester.pumpAndSettle();
    expect(find.text('Forgot password?'), findsNothing);
  });
}