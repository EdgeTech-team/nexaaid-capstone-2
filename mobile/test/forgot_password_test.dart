import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/forgot_password_screen.dart';
import 'package:mobile/ui/login_screen.dart';

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  testWidgets('Login has "Forgot password?" which opens the reset screen '
      'with the typed email', (tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light(), home: const LoginScreen()),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Email'),
      'me@example.com',
    );
    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();

    expect(find.text('Forgot password'), findsOneWidget); // app bar title
    expect(find.text('Send code'), findsOneWidget);
    expect(find.text('me@example.com'), findsOneWidget); // carried over
  });

  testWidgets('Send code needs a valid email', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const ForgotPasswordScreen(),
      ),
    );
    await tester.tap(find.text('Send code'));
    await tester.pump();
    expect(find.text('Email is required'), findsOneWidget);
  });
} 