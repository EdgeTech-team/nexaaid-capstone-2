// F-10: after a password change the server ends every older token and sends
// this device a new one; the app must keep using (and saving) the new one.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/api.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart'
;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('changing the password keeps the session with the new token', () async {
    SharedPreferences.setMockInitialValues({});
    final api = Api.instance;
    FlutterSecureStorage.setMockInitialValues({});
    api.logout();
    final sentWith = <String?>[];
    final server = MockClient((req) async {
      sentWith.add(req.headers['Authorization']);
      final body = switch (req.url.path) {
        '/token' => {
          'access_token': 'old-token',
          'token_type': 'bearer',
          'user': {'must_change_password': true},
        },
        '/health/secure' => {'status': 'ok', 'role': 'CSWS Main Office'},
        '/auth/change-password' => {
          'detail': 'Password changed',
          'must_change_password': false,
          'access_token': 'new-token',
          'token_type': 'bearer',
        },
        '/auth/me' => {'must_change_password': false},
        _ => {'detail': 'not mocked'},
      };
      return http.Response(jsonEncode(body), 200);
    });

    await http.runWithClient(() async {
      expect(
        (await api.login('staff@example.com', 'Temp#Pass2026')).ok,
        isTrue,
      );
      expect(api.mustChangePassword, isTrue);
      final r = await api.changePassword(
        'Temp#Pass2026',
        'Bagong#Pass2026',
        'Bagong#Pass2026',
      );
      expect(r.ok, isTrue);
      expect(api.loggedIn, isTrue);
      expect(api.token, 'new-token');
      expect(api.mustChangePassword, isFalse);
      await api.get('/auth/me');
      expect(sentWith.last, 'Bearer new-token');
    }, () => server);

    // The new token is what the app restores the next time it opens.
    final prefs = await SharedPreferences.getInstance();
    expect(
      await const FlutterSecureStorage().read(key: 'session_token'),
      'new-token',
    );
    expect(prefs.getString('session_token'), isNull); // F-12: no plain copy
    expect(prefs.getBool('session_must_change'), isFalse);
    api.logout();
  });
}
