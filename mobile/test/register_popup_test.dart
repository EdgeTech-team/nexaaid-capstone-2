// UI concern (new notes): registration opens as a pop-up over the blurred
// landing page, like the login, and the login pop-up only logs in.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/login_screen.dart';
import 'package:mobile/ui/register_screen.dart';

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  Widget host(void Function(BuildContext) open) => MaterialApp(
    theme: AppTheme.light(),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => open(context),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );

  for (final org in [false, true]) {
    final title = org ? 'Register organization' : 'Register as donor';

    testWidgets('$title opens as a blurred pop-up and closes with X', (
      tester,
    ) async {
      await tester.pumpWidget(host((c) => showRegisterPopup(c, org: org)));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(find.text(title), findsOneWidget);
      expect(find.byTooltip('Back'), findsNothing); // X instead of Back

      // A stray tap outside keeps the form (and what was typed).
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(find.text(title), findsOneWidget);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text(title), findsNothing);
      expect(find.text('Open'), findsOneWidget);
    });
  }

  testWidgets('Login pop-up has no register or guest buttons', (tester) async {
    await tester.pumpWidget(host(showLoginPopup));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Forgot password?'), findsOneWidget);
    expect(find.text('Register as donor'), findsNothing);
    expect(find.text('Register organization'), findsNothing);
    expect(find.text('Donate as guest'), findsNothing);
  });
}