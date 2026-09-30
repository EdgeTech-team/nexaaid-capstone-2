import 'dart:convert';

import 'package:flutter/material.dart';

import 'api.dart';

/// One input on an [ApiForm].
class F {
  final String key;
  final String label;
  final String initial;
  final bool number;
  final bool obscure;
  final List<String>? options; // shows a dropdown instead of a text field
  final String? hint;
  const F(this.key, this.label,
      {this.initial = '',
      this.number = false,
      this.obscure = false,
      this.options,
      this.hint});
}

/// Reads form values: `v.s('x')` text or null, `v.i('x')` int or null.
class Values {
  final Map<String, String> raw;
  Values(this.raw);
  String? s(String k) {
    final t = raw[k]?.trim() ?? '';
    return t.isEmpty ? null : t;
  }

  int? i(String k) => int.tryParse(raw[k]?.trim() ?? '');
  double? d(String k) => double.tryParse(raw[k]?.trim() ?? '');
}

/// A card with a few inputs, one button and the HTTP result under it.
/// Every screen in the test app is built out of these.
class ApiForm extends StatefulWidget {
  final String title;
  final String? subtitle;
  final List<F> fields;
  final String button;
  final Future<ApiResult> Function(Values v) onSubmit;

  /// Extra widget shown under a successful result (e.g. the QR image).
  final Widget? Function(ApiResult r)? extra;

  const ApiForm({
    super.key,
    required this.title,
    this.subtitle,
    this.fields = const [],
    this.button = 'Send',
    required this.onSubmit,
    this.extra,
  });

  @override
  State<ApiForm> createState() => _ApiFormState();
}

class _ApiFormState extends State<ApiForm> {
  late final Map<String, TextEditingController> _c = {
    for (final f in widget.fields) f.key: TextEditingController(text: f.initial)
  };
  bool busy = false;
  ApiResult? result;

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => busy = true);
    final r = await widget.onSubmit(
        Values({for (final e in _c.entries) e.key: e.value.text}));
    if (!mounted) return;
    setState(() {
      busy = false;
      result = r;
    });
  }

  Widget _input(F f) {
    final c = _c[f.key]!;
    if (f.options != null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: DropdownButtonFormField<String>(
          initialValue: c.text.isEmpty ? null : c.text,
          items: [
            for (final o in f.options!)
              DropdownMenuItem(value: o, child: Text(o)),
          ],
          onChanged: (v) => c.text = v ?? '',
          decoration: InputDecoration(
              labelText: f.label,
              border: const OutlineInputBorder(),
              isDense: true),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: c,
        obscureText: f.obscure,
        keyboardType: f.number ? TextInputType.number : TextInputType.text,
        decoration: InputDecoration(
          labelText: f.label,
          hintText: f.hint,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = result;
    final card = Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.title,
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            if (widget.subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(widget.subtitle!,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
            const SizedBox(height: 10),
            for (final f in widget.fields) _input(f),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                onPressed: busy ? null : _submit,
                child: Text(widget.button),
              ),
            ),
            if (busy)
              const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: LinearProgressIndicator()),
            if (r != null) ResultBox(r),
            if (r != null && r.ok && widget.extra != null)
              widget.extra!(r) ?? const SizedBox.shrink(),
          ],
        ),
      ),
    );
    // Labelled container so each card is one unit for screen readers
    // (and for the browser-driven test script).
    return Semantics(
        container: true,
        explicitChildNodes: true,
        identifier: widget.title,
        child: card);
  }
}

Color statusColor(int status) {
  if (status == 0) return Colors.grey;
  if (status < 300) return Colors.green;
  if (status == 401 || status == 403) return Colors.orange;
  if (status == 404) return Colors.blueGrey;
  if (status == 422 || status == 400 || status == 409) return Colors.deepPurple;
  return Colors.red;
}

/// Shows HTTP status + response body (or the error detail).
class ResultBox extends StatelessWidget {
  final ApiResult result;
  const ResultBox(this.result, {super.key});

  @override
  Widget build(BuildContext context) {
    final r = result;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: statusColor(r.status)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Chip(
            label: Text(r.status == 0 ? 'NETWORK ERROR' : 'HTTP ${r.status}',
                style: const TextStyle(color: Colors.white)),
            backgroundColor: statusColor(r.status),
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: SingleChildScrollView(
              child: SelectableText(
                r.ok ? r.pretty : r.errorText,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Renders the raw base64 PNG returned by GET /donations/{id}/qr.
Widget? qrImage(ApiResult r) {
  final j = r.json;
  if (j is! Map || j['qr_image_base64'] is! String) return null;
  return Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Column(children: [
      Text('QR code ${j['qr_reference']}'),
      const SizedBox(height: 6),
      Image.memory(base64Decode(j['qr_image_base64'] as String),
          width: 200, height: 200),
    ]),
  );
}

/// Tomorrow 08:00 as an ISO string, the default for date fields.
String tomorrowIso() {
  final t = DateTime.now().add(const Duration(days: 1));
  final d = DateTime(t.year, t.month, t.day, 8);
  return d.toIso8601String().split('.').first;
}

/// Standard page wrapper for a module screen.
class ModulePage extends StatelessWidget {
  final String title;
  final String? note;
  final List<Widget> children;
  const ModulePage(
      {super.key, required this.title, this.note, required this.children});

  @override
  Widget build(BuildContext context) {
    final api = Api.instance;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title),
            Text(
                api.loggedIn
                    ? '${api.email} - ${api.role ?? "?"}'
                    : 'Not logged in (guest)',
                style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(note!, style: const TextStyle(fontSize: 13)),
            ),
          ...children,
        ],
      ),
    );
  }
}
