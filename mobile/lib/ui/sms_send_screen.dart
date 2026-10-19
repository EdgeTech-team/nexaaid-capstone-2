import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

//import '../api.dart';
import 'input_formatters.dart';
import 'report_screens.dart' show maxAffectedFamilies, maxEstimatedQuantity;
import 'sitio_picker.dart';
import 'sms_report_format.dart';
import 'widgets.dart';

// ---------------------------------------------------------------------------
// SMS-Based Alternative Reporting (Scope 2.4, UC-A3 alt 8a, UC-CD1 alt
// 11b; Oct 15 team: back to the manuscript, claude/sms-reporting-decision.md).
// The CSWS Disaster Unit, with no internet, fills this form and sends the
// report as a text in the structured format (sms_report_format.dart).
// "Open SMS app" opens the phone's messaging app with the text already
// written and EVERY Administrator number already filled in as recipients;
// the Disaster Unit only taps Send. An Administrator who receives it
// reviews it and encodes it ("Encode SMS"), then validates it as usual.
// NexaAid only builds the text here.
//
// Works offline: the dropdown lists and the Administrators' SMS numbers are
// saved on the phone every time this screen opens with internet.
//
// Draft: what is typed is saved on the phone as it is typed, and comes back
// after a refresh or restart (also offline). "Clear the form (new report)"
// empties the form and the saved draft. "Open SMS app" keeps the draft, so
// a message that was never sent is not lost.
// ---------------------------------------------------------------------------

const _cacheLookups = 'sms_cache_lookups';
// v3: the receivers are the Administrators again (v2 held the Disaster
// Unit, from when the Barangay Rep sent the SMS).
const _cacheReceivers = 'sms_cache_receivers_admin';
const _cacheSavedAt = 'sms_cache_saved_at';
const _cacheDraft = 'sms_draft_v1';

class SmsSendScreen extends StatefulWidget {
  const SmsSendScreen({super.key});

  @override
  State<SmsSendScreen> createState() => _SmsSendScreenState();
}

class _NeedLine {
  String? item;
  final itemText = TextEditingController();
  final qty = TextEditingController();
  final unit = TextEditingController();

  bool get isBlank =>
      item == null &&
      itemText.text.trim().isEmpty &&
      qty.text.trim().isEmpty &&
      unit.text.trim().isEmpty;

  void dispose() {
    itemText.dispose();
    qty.dispose();
    unit.dispose();
  }
}

class _SmsSendScreenState extends State<SmsSendScreen> {
  final _form = GlobalKey<FormState>();

  // Saved on the phone (see _load).
  Map<String, dynamic> lookups = const {};
  List<Map> receivers = const [];
  String? savedAt;
  bool loading = true;
  bool online = false;

  SharedPreferences? _prefs;

  /// Draft saving starts only after the saved draft has been put back.
  bool _draftReady = false;

  /// Changing this rebuilds the form fields (used by "Clear the form").
  int _epoch = 0;

  /// Typed by hand only when no Administrator number is saved yet.
  final to = TextEditingController();

  /// The Administrator numbers the text goes to: all of them, unless the
  /// sender leaves some out.
  final picked = <String>{};
  bool _choseReceivers = false;
  String? type, barangay;

  /// Sitio names, one per row ('' = not chosen); see SitioPicker.
  List<String> sitioRows = [''];
  final typeText = TextEditingController();
  final barangayText = TextEditingController();
  final sitioText = TextEditingController();
  final families = TextEditingController();
  final details = TextEditingController();
  final needs = <_NeedLine>[_NeedLine()];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [
      to,
      typeText,
      barangayText,
      sitioText,
      families,
      details,
    ]) {
      c.dispose();
    }
    for (final n in needs) {
      n.dispose();
    }
    super.dispose();
  }

  /// Show what is saved on the phone first, then try to refresh it.
  Future<void> _load() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      final l = prefs.getString(_cacheLookups);
      final r = prefs.getString(_cacheReceivers);
      if (l != null) lookups = Map<String, dynamic>.from(jsonDecode(l) as Map);
      if (r != null) receivers = (jsonDecode(r) as List).cast<Map>();
      savedAt = prefs.getString(_cacheSavedAt);
    } catch (e) {
      debugPrint('SMS screen: could not read saved data: $e');
    }
    if (!mounted) return;
    _prefs = prefs;
    _restoreDraft(prefs);
    _draftReady = true;
    _pickAllReceivers();
    setState(() => loading = false);

    try {
      final fresh = await api.lookups().timeout(const Duration(seconds: 8));
      final r = await api
          .get('/contacts/sms-receivers')
          .timeout(const Duration(seconds: 8));
      lookups = Map<String, dynamic>.from(fresh);
      if (r.ok && r.json is List) receivers = (r.json as List).cast<Map>();
      savedAt = DateTime.now().toIso8601String();
      online = true;
      await prefs?.setString(_cacheLookups, jsonEncode(lookups));
      await prefs?.setString(_cacheReceivers, jsonEncode(receivers));
      await prefs?.setString(_cacheSavedAt, savedAt!);
      _pickAllReceivers();
      if (mounted && _reconcileChoices()) _epoch++;
    } catch (_) {
      online = false; // No internet: keep using what is saved.
    }
    if (mounted) {
      setState(() {});
      _saveDraft();
    }
  }

  // -------------------------------------------------------------------------
  // Draft (saved on the phone)
  // -------------------------------------------------------------------------

  bool get _draftEmpty =>
      type == null &&
      barangay == null &&
      [
        typeText,
        barangayText,
        sitioText,
        families,
        details,
        to,
      ].every((c) => c.text.trim().isEmpty) &&
      sitioRows.every((r) => r.isEmpty) &&
      needs.every((n) => n.isBlank);

  Map<String, dynamic> get _draftJson => {
    'type': type,
    'typeText': typeText.text,
    'barangay': barangay,
    'barangayText': barangayText.text,
    'sitioRows': sitioRows,
    'sitioText': sitioText.text,
    'families': families.text,
    'details': details.text,
    'to': to.text,
    'needs': [
      for (final n in needs)
        {
          'item': n.item,
          'itemText': n.itemText.text,
          'qty': n.qty.text,
          'unit': n.unit.text,
        },
    ],
  };

  /// Saves what is typed. Called on every change; nothing is saved until the
  /// old draft has been put back (so it is never overwritten by an empty one).
  void _saveDraft() {
    final p = _prefs;
    if (!mounted || !_draftReady || p == null) return;
    try {
      if (_draftEmpty) {
        unawaited(p.remove(_cacheDraft));
      } else {
        unawaited(p.setString(_cacheDraft, jsonEncode(_draftJson)));
      }
    } catch (e) {
      debugPrint('SMS screen: could not save the draft: $e');
    }
  }

  /// Puts the saved draft back. A dropdown choice only comes back if it is
  /// still in the lists saved on the phone; typed text always comes back.
  void _restoreDraft(SharedPreferences? prefs) {
    try {
      final raw = prefs?.getString(_cacheDraft);
      if (raw == null) return;
      final d = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      String s(String key) => '${d[key] ?? ''}';

      typeText.text = s('typeText');
      barangayText.text = s('barangayText');
      sitioText.text = s('sitioText');
      families.text = s('families');
      details.text = s('details');
      to.text = s('to');

      final t = d['type'] as String?;
      type = t != null && _namesOf('disaster_types').contains(t) ? t : null;
      final b = d['barangay'] as String?;
      barangay = b != null && _namesOf('barangays').contains(b) ? b : null;

      final sitios = _sitiosOf(barangay);
      final rows = [for (final r in (d['sitioRows'] as List? ?? const [])) '$r']
          .where((r) => sitios.contains(r))
          .toList();
      sitioRows = rows.isEmpty ? [''] : rows;

      final items = _namesOf('items');
      final lines = <_NeedLine>[];
      for (final raw in (d['needs'] as List? ?? const [])) {
        final m = Map<String, dynamic>.from(raw as Map);
        final n = _NeedLine();
        final item = m['item'] as String?;
        n.item = item != null && items.contains(item) ? item : null;
        n.itemText.text = '${m['itemText'] ?? ''}';
        n.qty.text = '${m['qty'] ?? ''}';
        n.unit.text = '${m['unit'] ?? ''}';
        lines.add(n);
      }
      if (lines.isNotEmpty) {
        for (final n in needs) {
          n.dispose();
        }
        needs
          ..clear()
          ..addAll(lines);
      }
    } catch (e) {
      debugPrint('SMS screen: could not read the saved draft: $e');
    }
  }

  /// After the lists were refreshed from the server: drop choices that no
  /// longer exist, and turn text typed while offline into a dropdown choice
  /// when it matches a name. Returns true if something changed.
  bool _reconcileChoices() {
    var changed = false;

    String? fix(String? v, String text, List<String> options) {
      if (options.isEmpty) return v;
      if (v != null && options.contains(v)) return v;
      final t = text.trim().toLowerCase();
      if (t.isNotEmpty) {
        for (final o in options) {
          if (o.toLowerCase() == t) return o;
        }
      }
      return null;
    }

    final t2 = fix(type, typeText.text, _namesOf('disaster_types'));
    if (t2 != type) {
      type = t2;
      changed = true;
    }
    final b2 = fix(barangay, barangayText.text, _namesOf('barangays'));
    if (b2 != barangay) {
      barangay = b2;
      sitioRows = [''];
      changed = true;
    }
    final sitios = _sitiosOf(barangay);
    if (sitios.isNotEmpty &&
        sitioRows.any((r) => r.isNotEmpty && !sitios.contains(r))) {
      final keep = [
        for (final r in sitioRows)
          if (sitios.contains(r)) r,
      ];
      sitioRows = keep.isEmpty ? [''] : keep;
      changed = true;
    }
    final items = _namesOf('items');
    for (final n in needs) {
      final i2 = fix(n.item, n.itemText.text, items);
      if (i2 != n.item) {
        n.item = i2;
        changed = true;
      }
    }
    return changed;
  }

  /// "Clear the form (new report)": empties the form and the saved draft.
  Future<void> _clearForm() async {
    setState(() {
      type = null;
      barangay = null;
      sitioRows = [''];
      typeText.clear();
      barangayText.clear();
      sitioText.clear();
      families.clear();
      details.clear();
      to.clear();
      needs
        ..clear()
        ..add(_NeedLine());
      _epoch++;
    });
    try {
      await _prefs?.remove(_cacheDraft);
    } catch (e) {
      debugPrint('SMS screen: could not clear the draft: $e');
    }
  }

  void _pickAllReceivers() {
    if (_choseReceivers) return;
    picked
      ..clear()
      ..addAll(_receiverNumbers);
  }

  List<String> get _receiverNumbers => [
    for (final r in receivers)
      if ('${r['contact_number'] ?? ''}'.trim().isNotEmpty)
        '${r['contact_number']}'.trim(),
  ];

  /// Who the text goes to, in the saved order.
  List<String> get _recipients => _receiverNumbers.isEmpty
      ? [to.text.trim()]
      : [
          for (final n in _receiverNumbers)
            if (picked.contains(n)) n,
        ];

  Names get _names => Names(lookups);

  List<String> _namesOf(String list) {
    try {
      return [
        for (final r in _names.rows(list))
          _names
              .of(list, r['id'], fallback: '')
              .replaceAll(RegExp(r'\s*\(.*\)$'), ''),
      ].where((n) => n.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }

  String? _barangayId(String? name) {
    if (name == null) return null;
    for (final r in _names.rows('barangays')) {
      if (_names.of('barangays', r['id'], fallback: '') == name) {
        return '${r['id']}';
      }
    }
    return null;
  }

  List<String> _sitiosOf(String? barangayName) {
    final id = _barangayId(barangayName);
    if (id == null) return const [];
    return [
      for (final s in _names.rows('sitios'))
        if ('${s['barangay_id']}' == id) '${s['name']}',
    ];
  }

  String _unitOf(String? itemName) {
    for (final r in _names.rows('items')) {
      final n = _names
          .of('items', r['id'], fallback: '')
          .replaceAll(RegExp(r'\s*\(.*\)$'), '');
      if (n == itemName) return '${r['unit'] ?? ''}';
    }
    return '';
  }

  /// A dropdown when the list is saved on the phone, otherwise a text field.
  Widget _choice({
    required String label,
    required List<String> options,
    required String? value,
    required TextEditingController text,
    required ValueChanged<String?> onChanged,
    bool required = true,
    String? firstOption,
    Key? key,
  }) {
    if (options.isEmpty) {
      return TextFormField(
        key: key,
        controller: text,
        decoration: InputDecoration(labelText: label),
        validator: required
            ? (v) => (v ?? '').trim().isEmpty ? 'Required' : null
            : null,
      );
    }
    return DropdownButtonFormField<String>(
      key: key,
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        if (firstOption != null)
          DropdownMenuItem(value: '', child: Text(firstOption)),
        for (final o in options) DropdownMenuItem(value: o, child: Text(o)),
      ],
      onChanged: onChanged,
      validator: required ? (v) => v == null ? 'Choose one' : null : null,
    );
  }

  String _val(String? picked, TextEditingController text) =>
      (picked ?? text.text).trim();

  SmsReport get _report => SmsReport(
    disasterType: _val(type, typeText),
    barangay: _val(barangay, barangayText),
    sitio: () {
      final s = _sitiosOf(barangay).isEmpty
          ? sitioText.text.trim()
          : sitioRows.where((r) => r.isNotEmpty).join(', ');
      return s.isEmpty ? null : s;
    }(),
    families: int.tryParse(families.text.trim()),
    needs: [
      for (final n in needs)
        if (int.tryParse(n.qty.text.trim()) != null &&
            _val(n.item, n.itemText).isNotEmpty)
          SmsNeed(
            _val(n.item, n.itemText),
            int.parse(n.qty.text.trim()),
            n.unit.text.trim(),
          ),
    ],
    details: details.text.trim().isEmpty ? null : details.text.trim(),
  );

  bool _check() {
    if (!_form.currentState!.validate()) return false;
    if (_recipients.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Choose at least one Administrator number.'),
        ),
      );
      return false;
    }
    final missing = _report.missing;
    if (missing.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Still missing: ${missing.join(', ')}.')),
      );
      return false;
    }
    return true;
  }

  /// Opens the messaging app. The draft is kept on purpose: if the message
  /// is not sent, nothing is lost.
  Future<void> _openSmsApp() async {
    if (!_check()) return;
    final ok = await launchUrl(smsUri(_recipients, _report.toMessage()))
        .catchError((_) => false);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not open the messaging app. Type the text above in a '
            'new message to the Administrator numbers.',
          ),
        ),
      );
    }
  }

  Widget _needRow(int i, List<String> items) {
    final n = needs[i];
    return Card(
      key: ObjectKey(n),
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: _choice(
                    label: 'Need ${i + 1}',
                    options: items,
                    value: n.item,
                    text: n.itemText,
                    onChanged: (v) {
                      setState(() {
                        n.item = v;
                        final u = _unitOf(v);
                        if (u.isNotEmpty) n.unit.text = u;
                      });
                      _saveDraft();
                    },
                  ),
                ),
                if (needs.length > 1)
                  IconButton(
                    tooltip: 'Remove this need',
                    onPressed: () {
                      setState(() => needs.removeAt(i));
                      _saveDraft();
                    },
                    icon: const Icon(Icons.close),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: n.qty,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    decoration: const InputDecoration(labelText: 'How many?'),
                    validator: (v) {
                      final q = int.tryParse(v?.trim() ?? '');
                      if (q == null || q <= 0) return 'Enter a number above 0';
                      if (q > maxEstimatedQuantity) {
                        return 'Maximum is $maxEstimatedQuantity';
                      }
                      return null;
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextFormField(
                    controller: n.unit,
                    decoration: const InputDecoration(
                      labelText: 'Unit',
                      hintText: 'kg, packs, boxes',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    final t = Theme.of(context).textTheme;
    final items = _namesOf('items');
    final sitios = _sitiosOf(barangay);
    return Form(
      key: _form,
      // Typing in any text field saves the draft. Dropdowns, sitios and
      // needs save from their own handlers (they change state after this).
      onChanged: _saveDraft,
      child: ListView(
        key: ValueKey('sms-form-$_epoch'),
        padding: const EdgeInsets.all(20),
        children: [
          const PageHeader(
            'Prepare an SMS Report',
            subtitle:
                'For when there is no internet. Fill this in to make a text in '
                'the NexaAid format and send it from your phone to the '
                'Administrator. They review and encode it as a report, then '
                'validate it.',
          ),
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 18),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'NexaAid does not send this message. Your phone\'s '
                    'messaging app does, using regular text (no internet needed).',
                  ),
                ),
              ],
            ),
          ),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: Icon(online ? Icons.wifi : Icons.wifi_off),
              title: Text(online ? 'Online' : 'Offline'),
              subtitle: Text(
                savedAt == null
                    ? 'Nothing saved on this phone yet. Open this screen once '
                          'with internet so it works offline later.'
                    : 'Lists and numbers saved on this phone: ${niceDate(savedAt)}',
              ),
            ),
          ),
          const SectionTitle('Send to'),
          if (_receiverNumbers.isNotEmpty) ...[
            Text(
              'The text goes to every Administrator number below, filled in '
              'for you. Tap a number to leave it out.',
              style: t.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final r in receivers)
                  if ('${r['contact_number'] ?? ''}'.trim().isNotEmpty)
                    FilterChip(
                      label: Text('${r['name']} · ${r['contact_number']}'),
                      selected: picked.contains(
                        '${r['contact_number']}'.trim(),
                      ),
                      onSelected: (on) => setState(() {
                        _choseReceivers = true;
                        final n = '${r['contact_number']}'.trim();
                        on ? picked.add(n) : picked.remove(n);
                      }),
                    ),
              ],
            ),
          ] else ...[
            Text(
              'No Administrator numbers saved yet. Open this screen once with '
              'internet, or type the number you were given.',
              style: t.bodySmall,
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: to,
              keyboardType: TextInputType.phone,
              inputFormatters: phoneFormatters,
              decoration: const InputDecoration(
                labelText: 'Administrator SMS number',
                hintText: '09XXXXXXXXX',
              ),
              validator: (v) => RegExp(r'^09\d{9}$').hasMatch((v ?? '').trim())
                  ? null
                  : 'Mobile number, 11 digits, e.g. 09171234567',
            ),
          ],
          const SectionTitle('Disaster and location'),
          _choice(
            label: 'Disaster type',
            options: _namesOf('disaster_types'),
            value: type,
            text: typeText,
            onChanged: (v) {
              setState(() => type = v);
              _saveDraft();
            },
          ),
          const SizedBox(height: 12),
          _choice(
            label: 'Barangay',
            options: _namesOf('barangays'),
            value: barangay,
            text: barangayText,
            onChanged: (v) {
              setState(() {
                barangay = v;
                sitioRows = [''];
              });
              _saveDraft();
            },
          ),
          // problema_napud 2.2: only the chosen barangay's sitios, and
          // "Add another sitio" when more than one was hit.
          if (sitios.isNotEmpty) ...[
            const SizedBox(height: 12),
            SitioPicker(
              key: ValueKey('sitios-$barangay'),
              options: {for (final n in sitios) n: n},
              rows: sitioRows,
              onChanged: (rows) {
                setState(() => sitioRows = rows);
                _saveDraft();
              },
            ),
          ] else if (_namesOf('barangays').isEmpty) ...[
            // Nothing saved on the phone: type the sitio names.
            const SizedBox(height: 12),
            TextFormField(
              controller: sitioText,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Sitio',
                helperText:
                    'Leave empty for the whole barangay. Several? Separate '
                    'them with commas.',
              ),
            ),
          ],
          const SectionTitle('Situation (DROMIC)'),
          TextFormField(
            controller: families,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            decoration: const InputDecoration(labelText: 'Affected families'),
            validator: (v) {
              final f = int.tryParse(v?.trim() ?? '');
              if (f == null || f <= 0) return 'Enter a number above 0';
              if (f > maxAffectedFamilies) {
                return 'Maximum is $maxAffectedFamilies';
              }
              return null;
            },
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: details,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'What happened (short)',
            ),
          ),
          SectionTitle(
            'Assistance needed',
            trailing: TextButton.icon(
              onPressed: () {
                setState(() => needs.add(_NeedLine()));
                _saveDraft();
              },
              icon: const Icon(Icons.add),
              label: const Text('Add need'),
            ),
          ),
          for (var i = 0; i < needs.length; i++) _needRow(i, items),
          const SectionTitle('Text that will be sent'),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                _report.toMessage(),
                style: t.bodyMedium?.copyWith(fontFamily: 'monospace'),
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _openSmsApp,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
            ),
            icon: const Icon(Icons.sms_outlined),
            label: const Text('Open SMS app'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _clearForm,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
            ),
            icon: const Icon(Icons.restart_alt),
            label: const Text('Clear the form (new report)'),
          ),
          const SizedBox(height: 8),
          Text(
            'What you type is saved on this phone, even without internet, '
            'until you clear the form.',
            style: t.bodySmall,
          ),
          const SizedBox(height: 8),
          Text(
            'Keypad phone? Type the same lines by hand: NEXAAID REPORT, '
            'TYPE:, BRGY:, SITIO:, FAMILIES:, NEEDS:, DETAILS:',
            style: t.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// sms: link with every recipient and the text already written (RFC 5724:
/// recipients separated by commas). The phone's messaging app opens with
/// both filled in; NexaAid itself never sends anything.
Uri smsUri(List<String> numbers, String body) =>
    Uri.parse('sms:${numbers.join(',')}?body=${Uri.encodeComponent(body)}');
