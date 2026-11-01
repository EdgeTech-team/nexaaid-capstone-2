// F-12: on Android and iOS the login token lives in the Keystore/Keychain
// (flutter_secure_storage), never in plain shared_preferences.
// flutter test runs as Android by default, so the phone path is tested.
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/api.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _secure = FlutterSecureStorage();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    Api.instance.logout();
    await pumpEventQueue(); // let logout finish clearing before the next test
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  final server = MockClient((req) async {
    final body = switch (req.url.path) {
      '/token' => {
        'access_token': 'phone-token',
        'token_type': 'bearer',
        'user': {'must_change_password': false},
      },
      '/health/secure' => {'status': 'ok', 'role': Roles.donor},
      _ => {'detail': 'not mocked'},
    };
    return http.Response(jsonEncode(body), 200);
  });

  test('signing in keeps the token in secure storage only', () async {
    await http.runWithClient(
      () => Api.instance.login('donor@example.com', 'any-password'),
      () => server,
    );
    expect(await _secure.read(key: 'session_token'), 'phone-token');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('session_token'), isNull);
    expect(prefs.getString('session_email'), 'donor@example.com');

    // Signing out removes it from secure storage too.
    Api.instance.logout();
    await pumpEventQueue();
    expect(await _secure.read(key: 'session_token'), isNull);
  });

  test('a session saved before F-12 moves to secure storage once', () async {
    SharedPreferences.setMockInitialValues({
      'session_token': 'old-token',
      'session_email': 'donor@example.com',
      'session_role': Roles.donor,
    });
    await Api.instance.restoreSession();
    expect(Api.instance.token, 'old-token');
    expect(Api.instance.role, Roles.donor);
    expect(await _secure.read(key: 'session_token'), 'old-token');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('session_token'), isNull); // plain copy gone

    // The next app start reads it from secure storage.
    Api.instance.token = null;
    await Api.instance.restoreSession();
    expect(Api.instance.token, 'old-token');
  });
}
