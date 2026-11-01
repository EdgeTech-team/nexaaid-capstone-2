// F-13: a release build has no "Server address" button and ignores any
// attempt to change the server; debug and profile builds keep both.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/landing/landing_screen.dart';

// Every public call fails, so the landing page shows its error view.
final _down = MockClient(
  (req) async => http.Response(jsonEncode({'detail': 'down'}), 500),
);

Future<void> _landing(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(theme: AppTheme.light(), home: const LandingScreen()),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);
  final defaultBase = Api.instance.baseUrl;
  tearDown(() {
    Api.instance.devOptions = true;
    Api.instance.baseUrl = defaultBase;
  });

  testWidgets('Debug/profile: the error view offers Server address', (
    tester,
  ) async {
    await http.runWithClient(() => _landing(tester), () => _down);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Server address'), findsOneWidget);
  });

  testWidgets('Release: no Server address button', (tester) async {
    Api.instance.devOptions = false;
    await http.runWithClient(() => _landing(tester), () => _down);
    expect(find.text('Try again'), findsOneWidget); // the error view is shown
    expect(find.text('Server address'), findsNothing);
  });

  test('Release: setBase is ignored', () {
    Api.instance.devOptions = false;
    Api.instance.setBase('http://evil.example');
    expect(Api.instance.baseUrl, defaultBase);
  });
}
