import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Role names exactly as they are in the `roles` table.
class Roles {
  static const admin = 'Administrator';
  static const donor = 'Individual Donor';
  static const org = 'Relief Organization';
  static const cmo = 'CMO Representative';
  static const cswsMain = 'CSWS Main Office';
  static const cswsUnit = 'CSWS Disaster Unit';
  static const barangay = 'Barangay Receiving Representative';
  static const drrmo = 'DRRMO Logistics Support';
}

/// Result of one API call.
class ApiResult {
  final int status; // 0 = network error / blocked by the browser
  final dynamic json; // decoded body, or null if not JSON
  final String raw;

  ApiResult(this.status, this.json, this.raw);

  bool get ok => status >= 200 && status < 300;

  String get pretty {
    if (json != null) {
      return const JsonEncoder.withIndent('  ').convert(json);
    }
    return raw.isEmpty ? '(empty response)' : raw;
  }

  /// Short human-readable error (FastAPI puts it in "detail").
  String get errorText {
    if (json is Map && json['detail'] != null) {
      final d = json['detail'];

      if (d is String) return d;

      // 422 from FastAPI: a list of {loc, msg, ...}.
      if (d is List && d.every((e) => e is Map && e['msg'] is String)) {
        return d
            .map((e) => (e['msg'] as String).replaceFirst('Value error, ', ''))
            .toSet()
            .join('\n');
      }

      return const JsonEncoder.withIndent('  ').convert(d);
    }

    return raw;
  }
}

/// Tiny API client + session state (token, email, role).
class Api extends ChangeNotifier {
  Api._();

  static final Api instance = Api._();

  // Default backend: deployed NexaAid Render service.
  // This avoids resetting to localhost when the app restarts.
  String baseUrl = _defaultBase();

  String? token;
  String? email;
  String? role;
  bool mustChangePassword = false;

  bool get loggedIn => token != null;

  /// Browsing as a guest donor (no account), UC-D2 allows this.
  bool guest = false;

  void continueAsGuest() {
    guest = true;
    notifyListeners();
  }

  // ---- Saved login: stays signed in after the app closes or the page refreshes ----

  static const _kToken = 'session_token';
  static const _kEmail = 'session_email';
  static const _kRole = 'session_role';
  static const _kMustChange = 'session_must_change';

  // F-12: on Android and iOS the login token is kept in the Android
  // Keystore / iOS Keychain, never in plain shared_preferences. The web and
  // desktop builds keep it in shared_preferences (browsers have no secure
  // store; a Content-Security-Policy protects the web build).
  static const _secure = FlutterSecureStorage();

  static bool get _onPhone =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> _writeToken(SharedPreferences p) async {
    if (!_onPhone) {
      await p.setString(_kToken, token ?? '');
      return;
    }
    if (token == null) {
      await _secure.delete(key: _kToken);
    } else {
      await _secure.write(key: _kToken, value: token);
    }
    await p.remove(_kToken); // no plain copy left on the phone
  }

  Future<String?> _readToken(SharedPreferences p) async {
    final plain = p.getString(_kToken);
    if (!_onPhone) return plain;
    // A session saved before F-12 moves to secure storage once.
    if (plain != null && plain.isNotEmpty) {
      await _secure.write(key: _kToken, value: plain);
      await p.remove(_kToken);
      return plain;
    }
    return _secure.read(key: _kToken);
  }

  Future<void> _saveSession() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kEmail, email ?? '');
      await p.setString(_kRole, role ?? '');
      await p.setBool(_kMustChange, mustChangePassword);
      await _writeToken(p);
    } catch (_) {}
  }

  Future<void> _clearSavedSession() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_kToken);
      await p.remove(_kEmail);
      await p.remove(_kRole);
      await p.remove(_kMustChange);
      if (_onPhone) await _secure.delete(key: _kToken);
    } catch (_) {}
  }

  /// Call once before runApp(). Restores the saved login without any network
  /// call, so the app opens straight to the role's home screen even while the
  /// Render backend is still waking up.
  Future<void> restoreSession() async {
    try {
      final p = await SharedPreferences.getInstance();
      final saved = await _readToken(p);
      if (saved == null || saved.isEmpty) return;
      token = saved;
      email = p.getString(_kEmail);
      final savedRole = p.getString(_kRole);
      role = (savedRole == null || savedRole.isEmpty) ? null : savedRole;
      mustChangePassword = p.getBool(_kMustChange) ?? false;
    } catch (_) {}
  }

  /// Runs in the background after startup: refreshes the role. If the saved
  /// token has expired, send() signs the user out (see the 401 check there).
  Future<void> validateSession() async {
    if (token == null) return;
    final me = await get('/health/secure');
    if (me.ok && me.json is Map) {
      final r = me.json['role']?.toString();
      if (r != null && r != role) {
        role = r;
        _lookups = null; // F-01: the lookup lists depend on the role

        await _saveSession();
        notifyListeners();
      }
    }
  }

  /// Dropdown data from GET /lookups:
  /// disaster_types, barangays, sitios, items, reports -> list of {id, name}.
  /// Cached; cleared after any change.
  Future<Map<String, dynamic>>? _lookups;

  Future<Map<String, dynamic>> lookups() => _lookups ??= get('/lookups').then(
    (r) => r.ok && r.json is Map
        ? Map<String, dynamic>.from(r.json as Map)
        : <String, dynamic>{},
  );

  /// Fresh (uncached) GET /lookups, for screens that load lists.
  Future<ApiResult> lookupsResult() => get('/lookups');

  void refreshLookups() {
    _lookups = null;
    notifyListeners();
  }

  /// Use the deployed backend on Android, Chrome, and other platforms.
  static String _defaultBase() {
    return 'https://nexaaid-1.onrender.com';
  }

  /// F-13: the server address and the developer tools exist only in debug
  /// and profile builds; a release build always uses the HTTPS default.
  /// Tests switch it off to check the release behaviour.
  bool devOptions = !kReleaseMode;

  void setBase(String v) {
    if (!devOptions) return;
    baseUrl = v.trim().replaceAll(RegExp(r'/+$'), '');
    refreshLookups();
  }

  Future<ApiResult> send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? form,
    Map<String, String>? query,
  }) async {
    try {
      var uri = Uri.parse('$baseUrl$path');

      if (query != null && query.isNotEmpty) {
        uri = uri.replace(queryParameters: query);
      }

      final req = http.Request(method, uri);

      if (token != null) {
        req.headers['Authorization'] = 'Bearer $token';
      }

      if (form != null) {
        req.bodyFields = form;
      } else if (body != null) {
        req.headers['Content-Type'] = 'application/json';
        req.body = jsonEncode(body);
      }

      final streamed = await req.send().timeout(const Duration(seconds: 20));

      final res = await http.Response.fromStream(streamed);

      dynamic decoded;

      try {
        decoded = jsonDecode(res.body);
      } catch (_) {
        decoded = null;
      }

      // A new report / item may now exist, so reload dropdowns.
      if (method != 'GET' &&
          res.statusCode < 300 &&
          !path.startsWith('/token')) {
        refreshLookups();
      }

      // The login expired or is invalid: sign out so the app goes back to the
      // landing page instead of showing errors on every screen.
      if (res.statusCode == 401 &&
          token != null &&
          decoded is Map &&
          decoded['detail'].toString().startsWith('Could not validate')) {
        logout();
      }

      return ApiResult(res.statusCode, decoded, res.body);
    } catch (e) {
      return ApiResult(
        0,
        null,
        'Network error: $e\n\n'
        'Check the internet connection and API base URL. '
        'If using the deployed backend, verify the Render service.',
      );
    }
  }

  Future<ApiResult> get(String path, {Map<String, String>? query}) =>
      send('GET', path, query: query);

  Future<ApiResult> post(String path, {Map<String, dynamic>? body}) =>
      send('POST', path, body: body ?? {});

  Future<ApiResult> patch(String path, {Map<String, dynamic>? body}) =>
      send('PATCH', path, body: body ?? {});

  Future<ApiResult> put(String path, {Map<String, dynamic>? body}) =>
      send('PUT', path, body: body ?? {});

  Future<ApiResult> delete(String path) => send('DELETE', path);

  /// POST /uploads as multipart form data (purpose + file).
  /// Sends bytes instead of a file path, so it works on Android and Chrome.
  Future<ApiResult> upload({
    required String purpose,
    required List<int> bytes,
    required String filename,
  }) async {
    try {
      final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/uploads'));

      if (token != null) {
        req.headers['Authorization'] = 'Bearer $token';
      }

      req.fields['purpose'] = purpose;

      req.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: filename),
      );

      final streamed = await req.send().timeout(const Duration(seconds: 60));

      final res = await http.Response.fromStream(streamed);

      dynamic decoded;

      try {
        decoded = jsonDecode(res.body);
      } catch (_) {
        decoded = null;
      }

      return ApiResult(res.statusCode, decoded, res.body);
    } catch (e) {
      return ApiResult(0, null, 'Network error: $e');
    }
  }

  /// Downloads a file the server only gives to allowed users.
  /// Private uploads: GET /uploads/{file_id} checks owner / Administrator.
  /// Returns (status, bytes); status 0 means the server was not reached.
  Future<(int, Uint8List?)> download(String path) async {
    try {
      final res = await http
          .get(
            Uri.parse('$baseUrl$path'),
            headers: {if (token != null) 'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 60));

      return (res.statusCode, res.statusCode == 200 ? res.bodyBytes : null);
    } catch (_) {
      return (0, null);
    }
  }

  // ---- Authentication ----

  Future<ApiResult> login(String emailIn, String password) async {
    final r = await send(
      'POST',
      '/token',
      form: {'username': emailIn.trim(), 'password': password},
    );

    if (r.ok && r.json is Map && r.json['access_token'] != null) {
      token = r.json['access_token'] as String;
      email = emailIn.trim();
      role = null;
      guest = false;
      // F-01: /lookups answers per account, so lists cached as a guest (or as
      // another account) must not be reused after signing in.
      _lookups = null;

      final user = r.json['user'];
      mustChangePassword = user is Map && user['must_change_password'] == true;

      final me = await get('/health/secure');

      if (me.ok && me.json is Map) {
        role = me.json['role']?.toString();
      }

      await _saveSession();
      notifyListeners();
    }

    return r;
  }

  /// POST /auth/forgot-password: emails a 6-digit code.
  Future<ApiResult> forgotPassword(String email) =>
      post('/auth/forgot-password', body: {'email': email.trim()});

  /// POST /auth/reset-password: emailed code plus the new password.
  Future<ApiResult> resetPassword(
    String email,
    String code,
    String newPassword,
    String confirm,
  ) => post(
    '/auth/reset-password',
    body: {
      'email': email.trim(),
      'code': code.trim(),
      'new_password': newPassword,
      'confirm_password': confirm,
    },
  );

  void logout() {
    token = null;
    email = null;
    role = null;
    guest = false;
    mustChangePassword = false;
    // F-01: staff-only lookup lists must not stay cached after signing out.
    _lookups = null;

    _clearSavedSession();
    notifyListeners();
  }

  /// POST /auth/change-password. Clears mustChangePassword on success.
  Future<ApiResult> changePassword(
    String current,
    String newPassword,
    String confirm,
  ) async {
    final r = await post(
      '/auth/change-password',
      body: {
        'current_password': current,
        'new_password': newPassword,
        'confirm_password': confirm,
      },
    );

    if (r.ok) {
      // F-10: the server ends every older token after a password change and
      // sends this device a fresh one.
      final fresh = r.json is Map ? r.json['access_token'] : null;
      if (fresh is String) token = fresh;
      mustChangePassword = false;
      await _saveSession();
      notifyListeners();
    }

    return r;
  }
}
