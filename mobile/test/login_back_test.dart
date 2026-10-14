import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile/ui/login_screen.dart';

void main() {
  testWidgets('Login opened from another page has a Back button that '
      'returns to it', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                ),
                child: const Text('Open login'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open login'));
    await tester.pumpAndSettle();
    expect(find.text('Back'), findsOneWidget);

    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Open login'), findsOneWidget);
    expect(find.text('Back'), findsNothing);
  });

  testWidgets('Login as the first page shows no Back button', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    expect(find.text('Back'), findsNothing);
  });
}