// Profile tab: a normal profile first; developer tools hidden until
// "About NexaAid" is tapped 5 times.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/profile_screen.dart';

final _server = MockClient((req) async {
  final body = switch (req.url.path) {
    '/auth/me' => {
      'user_id': 3,
      'first_name': 'Ana',
      'last_name': 'Reyes',
      'email': 'ana.test@example.com',
      'role_name': 'Barangay Receiving Representative',
      'organization_id': null,
      'assigned_barangay_id': 1,
    },
    '/lookups' => {
      'barangays': [
        {'id': 1, 'name': 'Tipolo'},
      ],
    },
    _ => {'detail': 'not mocked'},
  };
  return http.Response(jsonEncode(body), 200);
});

Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: const Scaffold(body: ProfileScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);
  setUp(() => ProfileScreen.devToolsShown.value = false);
  tearDown(() => Api.instance.token = null);

  testWidgets('Logged in: name, role, barangay; no developer tools', (
    tester,
  ) async {
    Api.instance.token = 'test-token';
    await http.runWithClient(() async {
      await _pump(tester);
      expect(find.text('Ana Reyes'), findsOneWidget);
      expect(find.text('AR'), findsOneWidget); // initials
      expect(find.text('Barangay Receiving Representative'), findsOneWidget);
      expect(find.text('ana.test@example.com'), findsOneWidget);
      expect(find.text('Tipolo'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Log out'), findsOneWidget);
      expect(find.text('Developer tools'), findsNothing);
      expect(find.text('API console'), findsNothing);
      expect(find.text('Design system gallery'), findsNothing);
    }, () => _server);
  });

  testWidgets('Five taps on About show developer tools; Hide hides them', (
    tester,
  ) async {
    await _pump(tester); // guest: no server needed
    expect(find.text('Guest donor'), findsOneWidget);
    expect(find.text('Back to start'), findsOneWidget);

    final about = find.byKey(const ValueKey('about-nexaaid'));
    for (var i = 0; i < 4; i++) {
      await tester.tap(about);
    }
    await tester.pump();
    expect(find.text('API console'), findsNothing);

    await tester.tap(about);
    await tester.pumpAndSettle();
    expect(find.text('Developer tools'), findsOneWidget);
    expect(find.text('API console'), findsOneWidget);
    expect(find.text('Design system gallery'), findsOneWidget);

    await tester.tap(find.text('Hide developer tools'));
    await tester.pumpAndSettle();
    expect(find.text('API console'), findsNothing);
  });
}
