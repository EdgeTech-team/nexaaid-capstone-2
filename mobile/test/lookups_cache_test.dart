// F-01: /lookups answers per account (the internal lists only reach the
// staff role that uses them), so the app must not reuse a copy cached for
// someone else, and the SMS screen keeps only the lists it needs on the phone.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/sms_send_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _staffToken = 'staff-token';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => AppTheme.useGoogleFonts = false);

  test('a lookup copy never outlives the account it was fetched for', () async {
    SharedPreferences.setMockInitialValues({});
    final api = Api.instance;
    api.logout();
    api.refreshLookups();
    var lookupRequests = 0;
    final server = MockClient((req) async {
      switch (req.url.path) {
        case '/lookups':
          lookupRequests++;
          final staff = req.headers['Authorization'] == 'Bearer $_staffToken';
          return http.Response(
            jsonEncode({
              'barangays': [
                {'id': 1, 'name': 'Banilad'},
              ],
              // The server fills this only for CSWS Main Office.
              'pending_donations': staff
                  ? [
                      {
                        'id': 7,
                        'name': '#7 DON-ABC123 - 5 kg Rice for report #1',
                      },
                    ]
                  : [],
            }),
            200,
          );
        case '/token':
          return http.Response(
            jsonEncode({
              'access_token': _staffToken,
              'token_type': 'bearer',
              'user': {'must_change_password': false},
            }),
            200,
          );
        case '/health/secure':
          return http.Response(
            jsonEncode({'status': 'ok', 'role': Roles.cswsMain}),
            200,
          );
      }
      return http.Response(jsonEncode({'detail': 'not mocked'}), 404);
    });

    await http.runWithClient(() async {
      // A guest: no internal list, and the copy is reused within the session.
      expect((await api.lookups())['pending_donations'], isEmpty);
      await api.lookups();
      expect(lookupRequests, 1);

      // Signing in fetches the lists again instead of reusing the guest copy.
      expect((await api.login('csws@example.com', 'any-password')).ok, isTrue);
      expect((await api.lookups())['pending_donations'], hasLength(1));
      await api.lookups();
      expect(lookupRequests, 2);

      // After signing out, nothing of the staff copy is left.
      api.logout();
      expect((await api.lookups())['pending_donations'], isEmpty);
      expect(lookupRequests, 3);
    }, () => server);
    api.logout();
  });

  testWidgets('the SMS screen saves only the lists it uses on the phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    Api.instance.logout();
    Api.instance.refreshLookups();
    final server = MockClient((req) async {
      final body = switch (req.url.path) {
        '/lookups' => {
          'disaster_types': [
            {'id': 1, 'name': 'Flood'},
          ],
          'barangays': [
            {'id': 1, 'name': 'Banilad'},
          ],
          'sitios': [],
          'items': [],
          // Internal lists must never reach the phone's offline copy.
          'reports': [
            {
              'id': 5,
              'name': '#5 Flood - Banilad (Pending)',
              'status': 'Pending',
            },
          ],
          'pending_donations': [
            {'id': 7, 'name': '#7 DON-ABC123 - 5 kg Rice for report #5'},
          ],
        },
        '/contacts/sms-receivers' => [
          {'name': 'Ana', 'contact_number': '09171111111'},
        ],
        _ => {'detail': 'not mocked'},
      };
      return http.Response(jsonEncode(body), 200);
    });
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: SmsSendScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }, () => server);

    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getString('sms_cache_lookups')!) as Map;
    expect(saved.keys.toSet(), {
      'disaster_types',
      'barangays',
      'sitios',
      'items',
    });
    expect(jsonEncode(saved), isNot(contains('DON-ABC123')));
  });
}
