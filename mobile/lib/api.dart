import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

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
    if (json != null) return const JsonEncoder.withIndent('  ').convert(json);
    return raw.isEmpty ? '(empty response)' : raw;
  }

  /// Short human-readable error (FastAPI puts it in "detail").
  String get errorText {
    if (json is Map && json['detail'] != null) {
      final d = json['detail'];
      if (d is String) return d;
      return const JsonEncoder.withIndent('  ').convert(d);
    }
    return raw;
  }
}

/// Tiny API client + session state (token, email, role).
class Api extends ChangeNotifier {
  Api._();
  static final Api instance = Api._();

  String baseUrl = _defaultBase();
  String? token;
  String? email;
  String? role;

  bool get loggedIn => token != null;

  /// Dropdown data from GET /lookups: disaster_types, barangays, sitios,
  /// items, reports -> list of {id, name}. Cached; cleared after any change.
  Future<Map<String, dynamic>>? _lookups;
  Future<Map<String, dynamic>> lookups() => _lookups ??= get('/lookups').then(
    (r) => r.ok && r.json is Map
        ? Map<String, dynamic>.from(r.json as Map)
        : <String, dynamic>{},
  );

  void refreshLookups() {
    _lookups = null;
    notifyListeners();
  }

  static String _defaultBase() {
    // The Android emulator reaches the host machine at 10.0.2.2
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return 'http://10.0.2.2:8000';
    }
    return 'http://localhost:8000';
  }

  void setBase(String v) {
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
      if (token != null) req.headers['Authorization'] = 'Bearer $token';
      if (form != null) {
        req.bodyFields = form; // sets the form content-type itself
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
      return ApiResult(res.statusCode, decoded, res.body);
    } catch (e) {
      return ApiResult(
        0,
        null,
        'Network error: $e\n\nIs uvicorn running and is the base URL right? '
        'In Chrome a server crash (500) also shows up here, so check the '
        'uvicorn terminal for a traceback.',
      );
    }
  }

  Future<ApiResult> get(String path, {Map<String, String>? query}) =>
      send('GET', path, query: query);
  Future<ApiResult> post(String path, {Map<String, dynamic>? body}) =>
      send('POST', path, body: body ?? {});
  Future<ApiResult> patch(String path, {Map<String, dynamic>? body}) =>
      send('PATCH', path, body: body ?? {});

  // ---- auth ----
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
      final me = await get('/health/secure');
      if (me.ok && me.json is Map) role = me.json['role']?.toString();
      notifyListeners();
    }
    return r;
  }

  void logout() {
    token = null;
    email = null;
    role = null;
    notifyListeners();
  }
}
