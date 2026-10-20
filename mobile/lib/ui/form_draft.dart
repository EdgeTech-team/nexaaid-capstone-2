import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';

// ---------------------------------------------------------------------------
// Testing fix (UI): typed text was lost when the page was refreshed or the
// app was closed. A FormDraft keeps what was typed on this device until the
// form is submitted. One draft per account and per form, so two people on
// the same phone or browser do not see each other's drafts.
//
// Use in a form:
//   late final _draft = FormDraft('donate:${reportId}');
//   initState: _draft.load().then((d) { if (d != null) ...fill fields... });
//   Form(onChanged: () => _draft.save(_snapshot), ...)
//   after a successful submit: _draft.clear();
//   dispose: _draft.flush(_snapshot);
// _snapshot returns a plain Map (strings, numbers, lists, maps).
// ---------------------------------------------------------------------------
class FormDraft {
  FormDraft(String form) : key = 'draft:${Api.instance.email ?? 'guest'}:$form';

  final String key;
  Timer? _timer;
  bool _cleared = false;

  /// The saved draft, or null when there is none.
  Future<Map<String, dynamic>?> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final s = p.getString(key);
      if (s == null || s.isEmpty) return null;
      final v = jsonDecode(s);
      return v is Map ? Map<String, dynamic>.from(v) : null;
    } catch (_) {
      return null;
    }
  }

  /// Saves shortly after the last change (not on every key press).
  void save(Map<String, dynamic> Function() snapshot) {
    _cleared = false;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 500), () => _write(snapshot()));
  }

  /// Saves now. Call from dispose() so the last few letters are kept too.
  void flush(Map<String, dynamic> Function() snapshot) {
    final pending = _timer?.isActive ?? false;
    _timer?.cancel();
    if (pending && !_cleared) _write(snapshot());
  }

  /// After a successful submit: forget the draft.
  Future<void> clear() async {
    _cleared = true;
    _timer?.cancel();
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(key);
    } catch (_) {}
  }

  Future<void> _write(Map<String, dynamic> data) async {
    if (_cleared) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(key, jsonEncode(data));
    } catch (_) {}
  }
}

/// Helpers for reading a draft map safely.
extension DraftRead on Map<String, dynamic> {
  String str(String k) => this[k] is String ? this[k] as String : '';
  String? strOrNull(String k) => this[k] is String ? this[k] as String : null;
  List<Map<String, dynamic>> maps(String k) => [
    for (final e in (this[k] is List ? this[k] as List : const []))
      if (e is Map) Map<String, dynamic>.from(e),
  ];
}
