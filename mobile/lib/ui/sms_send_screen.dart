import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import 'input_formatters.dart';
import 'report_screens.dart' show maxAffectedFamilies, maxEstimatedQuantity;
import 'sitio_picker.dart';
import 'sms_report_format.dart';
import 'widgets.dart';

// ---------------------------------------------------------------------------
// SMS-Based Alternative Reporting (Scope 2.4; Oct 12 team decision,
// claude/sms-reporting-decision.md).
// The Barangay Receiving Representative, with no internet, fills this form
// and sends the report as a text in the structured format
// (sms_report_format.dart). problema_napud 2.2: "Open SMS app" opens the
// phone's messaging app with the text already written and EVERY CSWS
// Disaster Unit number already filled in as recipients; the rep only taps
// Send. Any Disaster Unit member who receives it pastes it into
// "Encode SMS" and submits it as the unit's report; the Administrator
// validates it as usual. The rep does not create a report in the system
// (Scope 1.3): NexaAid only builds the text.
//
// Works offline: the dropdown lists and the Disaster Unit's SMS numbers are
// saved on the phone every time this screen opens with internet.
// ---------------------------------------------------------------------------

const _cacheLookups = 'sms_cache_lookups';
// v2: the receivers are now the Disaster Unit (v1 held Administrators).
const _cacheReceivers = 'sms_cache_receivers_unit';
const _cacheSavedAt = 'sms_cache_saved_at';

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
}

class _SmsSendScreenState extends State<SmsSendScreen> {
  final _form = GlobalKey<FormState>();

  // Saved on the phone (see _load).
  Map<String, dynamic> lookups = const {};
  List<Map> receivers = const [];
  String? savedAt;
  bool loading = true;
  bool online = false;

  /// Typed by hand only when no Disaster Unit number is saved yet.
  final to = TextEditingController();

  /// The Disaster Unit numbers the text goes to: all of them, unless the
  /// rep leaves some out.
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
    _pickAllReceivers();
    if (mounted) setState(() => loading = false);

    try {
      final fresh = await api.lookups().timeout(const Duration(seconds: 8));
      final r = await api
          .get('/contacts/disaster-unit')
          .timeout(const Duration(seconds: 8));
      lookups = Map<String, dynamic>.from(fresh);
      if (r.ok && r.json is List) receivers = (r.json as List).cast<Map>();
      savedAt = DateTime.now().toIso8601String();
      online = true;
      await prefs?.setString(_cacheLookups, jsonEncode(lookups));
      await prefs?.setString(_cacheReceivers, jsonEncode(receivers));
      await prefs?.setString(_cacheSavedAt, savedAt!);
      _pickAllReceivers();
    } catch (_) {
      online = false; // No internet: keep using what is saved.
    }
    if (mounted) setState(() {});
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
          content: Text('Choose at least one Disaster Unit number.'),
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

  Future<void> _openSmsApp() async {
    if (!_check()) return;
    final ok = await launchUrl(smsUri(_recipients, _report.toMessage()))
        .catchError((_) => false);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not open the messaging app. Type the text above in a '
            'new message to the Disaster Unit numbers.',
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
                    onChanged: (v) => setState(() {
                      n.item = v;
                      final u = _unitOf(v);
                      if (u.isNotEmpty) n.unit.text = u;
                    }),
                  ),
                ),
                if (needs.length > 1)
                  IconButton(
                    tooltip: 'Remove this need',
                    onPressed: () => setState(() => needs.removeAt(i)),
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
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const PageHeader(
            'Prepare an SMS Report',
            subtitle:
                'For when there is no internet. Fill this in to make a text in '
                'the NexaAid format and send it from your phone to the CSWS '
                'Disaster Unit. They encode it as a report, then the '
                'Administrator validates it.',
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
              'The text goes to every CSWS Disaster Unit number below, filled '
              'in for you. Tap a number to leave it out.',
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
              'No Disaster Unit numbers saved yet. Open this screen once with '
              'internet, or type the number you were given.',
              style: t.bodySmall,
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: to,
              keyboardType: TextInputType.phone,
              inputFormatters: phoneFormatters,
              decoration: const InputDecoration(
                labelText: 'CSWS Disaster Unit SMS number',
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
            onChanged: (v) => setState(() => type = v),
          ),
          const SizedBox(height: 12),
          _choice(
            label: 'Barangay',
            options: _namesOf('barangays'),
            value: barangay,
            text: barangayText,
            onChanged: (v) => setState(() {
              barangay = v;
              sitioRows = [''];
            }),
          ),
          // problema_napud 2.2: only the chosen barangay's sitios, and
          // "Add another sitio" when more than one was hit.
          if (sitios.isNotEmpty) ...[
            const SizedBox(height: 12),
            SitioPicker(
              key: ValueKey('sitios-$barangay'),
              options: {for (final n in sitios) n: n},
              rows: sitioRows,
              onChanged: (rows) => setState(() => sitioRows = rows),
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
              onPressed: () => setState(() => needs.add(_NeedLine())),
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
