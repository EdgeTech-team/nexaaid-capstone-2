import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import 'donation_info.dart' show NewReportDonationInfo;
import 'form_draft.dart';
import 'input_formatters.dart';
import 'records_screens.dart' show SupportRecordsScreen;
import 'report_filters.dart';
import 'report_summary_card.dart';
import 'sitio_picker.dart';
import 'quantity_units.dart';
import 'sms_report_format.dart';
import 'widgets.dart';
import 'home_nav.dart';

// ---------------------------------------------------------------------------
// Concerns2.txt 2.1: number limits. Must match the backend
// (app/schemas/report.py: MAX_AFFECTED_FAMILIES, MAX_ESTIMATED_QUANTITY).
// ---------------------------------------------------------------------------
const maxAffectedFamilies = 20000;
const maxEstimatedQuantity = 100000;

/// Only digits can be typed (no letters, dots, minus signs), up to 6 digits.
final _wholeNumberInput = <TextInputFormatter>[
  FilteringTextInputFormatter.digitsOnly,
  LengthLimitingTextInputFormatter(6),
];

/// 20000 -> "20,000"
String _withCommas(int n) =>
    n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

/// Validator: a whole number from 1 to [max].
String? Function(String?) _wholeNumber(int max) => (v) {
  final n = int.tryParse(v?.trim() ?? '');
  if (n == null || n <= 0) return 'Enter a number above 0';
  if (n > max) return 'Maximum is ${_withCommas(max)}';
  return null;
};

/// Card for one disaster report (with fulfillment if available). Resolves
/// the names and the role rule, then draws the shared [ReportSummaryCard]
/// (the landing page uses the same card).
class ReportCard extends StatelessWidget {
  final Map<String, dynamic> r;
  final Names names;
  final List<Widget> actions;

  /// Outlined: the report a notification pointed at.
  final bool highlighted;
  const ReportCard(
    this.r,
    this.names, {
    super.key,
    this.actions = const [],
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final hasFulfillment = r['total_items_needed'] != null;
    // Appendix H 3.2: every role except DRRMO views priority guidance.
    final showPriority = api.role != Roles.drrmo;
    final guidance = r['priority_guidance'] ?? r['ai_recommendation'];
    return ReportSummaryCard(
      reportId: (r['report_id'] as num?)?.toInt(),
      disaster: names.of('disaster_types', r['disaster_type_id']),
      barangay: names.of('barangays', r['barangay_id']),
      status: r['status'] as String?,
      priority: r['priority_level'] as String?,
      affectedFamilies: (r['affected_families'] as num?)?.toInt(),
      assistanceNeeded: r['assistance_needed']?.toString(),
      description: r['description']?.toString(),
      guidance: guidance?.toString(),
      rejectionReason: r['rejection_reason']?.toString(),
      delivered: hasFulfillment
          ? r['total_items_delivered'] as num? ?? 0
          : null,
      needed: hasFulfillment ? r['total_items_needed'] as num? ?? 0 : null,
      percent: hasFulfillment
          ? num.tryParse('${r['fulfillment_percentage']}')
          : null,
      showPriority: showPriority,
      highlighted: highlighted,
      actions: actions,
    );
  }
}

// ---------------------------------------------------------------------------
// UC-CD1 Submit post-disaster report (CSWS Disaster Unit), and
// Encode SMS report (Administrator, smsEncode: true).
// Scope 2.4, UC-A3 alt 8a, UC-CD1 alt 11b (Oct 15 team, back to the
// manuscript; claude/sms-reporting-decision.md): the Disaster Unit SENDS a
// structured SMS when offline (sms_send_screen.dart); the Administrator
// reviews and ENCODES it here, then validates it on the Validate tab.
// ---------------------------------------------------------------------------
class NewReportScreen extends StatefulWidget {
  /// true = Administrator encoding an SMS report the Disaster Unit sent.
  final bool smsEncode;

  /// Oct 11 (Daniel): the reporter corrects their own report before the
  /// Administrator validates it. The form opens filled in.
  final Map<String, dynamic>? edit;
  const NewReportScreen({super.key, this.smsEncode = false, this.edit});

  @override
  State<NewReportScreen> createState() => _NewReportScreenState();
}

/// One line of the needs list: an item (or "Other"), how many, and the unit.
class _Need {
  String? itemId; // items.item_id, or _other
  final qty = TextEditingController();
  final otherName = TextEditingController();
  final otherUnit = TextEditingController();
}

const _other = 'other';

class _NewReportScreenState extends State<NewReportScreen> {
  final _form = GlobalKey<FormState>();
  String? typeId, brgyId;

  /// problema_napud 2.2: one row per sitio hit, '' = not chosen yet. A
  /// single empty row means the whole barangay.
  List<String> sitioRows = [''];
  List<int> get _sitioIds => [
    for (final v in sitioRows.toSet())
      if (v.isNotEmpty) int.parse(v),
  ];
  final desc = TextEditingController();
  final families = TextEditingController();
  final smsSender = TextEditingController();
  final smsText = TextEditingController();
  final needs = <_Need>[_Need()];
  bool busy = false;

  /// true when encoding a report that arrived by SMS (UC-A3 8a).
  late final bool sms = widget.smsEncode;
  bool get editing => widget.edit != null;
  bool _filledFromEdit = false;

  // Testing fix (UI): what was typed survives a refresh or a closed app.
  // Not used when correcting an existing report.
  late final FormDraft? _draft = editing
      ? null
      : FormDraft(sms ? 'report-sms' : 'report');

  @override
  void initState() {
    super.initState();
    _draft?.load().then((d) async {
      if (d == null || !mounted) return;
      // The lists are needed to check the saved ids (cached after the
      // first load, so this is quick).
      final names = Names(await api.lookups());
      if (!mounted) return;
      setState(() => _applyDraft(d, names));
    });
  }

  @override
  void dispose() {
    _draft?.flush(_snapshot);
    super.dispose();
  }

  Map<String, dynamic> _snapshot() => {
    'type_id': typeId,
    'barangay_id': brgyId,
    'sitio_rows': sitioRows,
    'description': desc.text,
    'families': families.text,
    'sms_sender': smsSender.text,
    'sms_text': smsText.text,
    'needs': [
      for (final n in needs)
        {
          'item_id': n.itemId,
          'qty': n.qty.text,
          'other_name': n.otherName.text,
          'other_unit': n.otherUnit.text,
        },
    ],
  };

  void _saveDraft() => _draft?.save(_snapshot);

  /// Fills the form from the saved draft. Ids that no longer exist in the
  /// lists are skipped, so every dropdown gets a valid value.
  void _applyDraft(Map<String, dynamic> d, Names names) {
    bool known(String list, String? id) =>
        id != null && names.rows(list).any((r) => '${r['id']}' == id);
    final t = d.strOrNull('type_id');
    final b = d.strOrNull('barangay_id');
    typeId = known('disaster_types', t) ? t : null;
    brgyId = known('barangays', b) ? b : null;
    final rows = <String>[
      for (final v
          in (d['sitio_rows'] is List ? d['sitio_rows'] as List : const []))
        if (v is String &&
            (v.isEmpty ||
                names
                    .rows('sitios')
                    .any(
                      (st) =>
                          '${st['id']}' == v &&
                          '${st['barangay_id']}' == brgyId,
                    )))
          v,
    ];
    sitioRows = brgyId == null || rows.isEmpty ? [''] : rows;
    desc.text = d.str('description');
    families.text = d.str('families');
    smsSender.text = d.str('sms_sender');
    smsText.text = d.str('sms_text');
    _smsLen = smsText.text.length; // a restored SMS is not a new paste
    final restored = <_Need>[];
    for (final m in d.maps('needs')) {
      final id = m.strOrNull('item_id');
      final need = _Need()
        ..itemId = id == _other || known('items', id) ? id : null;
      need.qty.text = m.str('qty');
      need.otherName.text = m.str('other_name');
      need.otherUnit.text = m.str('other_unit');
      restored.add(need);
    }
    if (restored.isNotEmpty) {
      needs
        ..clear()
        ..addAll(restored);
    }
    _fills++; // the dropdowns rebuild with these values
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      AppToast.info(
        context,
        'We kept what you typed last time.',
        action: ToastAction('Start over', _startOver),
      );
    });
  }

  /// "Start over": an empty form and no draft.
  void _startOver() {
    _draft?.clear();
    setState(() {
      desc.clear();
      families.clear();
      smsSender.clear();
      smsText.clear();
      _smsLen = 0;
      needs
        ..clear()
        ..add(_Need());
      typeId = brgyId = null;
      sitioRows = [''];
      _fillNotes = const [];
      _fills++;
    });
  }

  /// Fill the form from the report being corrected. Per-item fulfillment
  /// (Oct 2026): the needs come back as rows (`needs`). Older reports only
  /// have one "General needs" row, so their text "Rice: 50 kg, Drinking
  /// Water: 20 L" is read instead.
  void _fillFromReport(Map<String, dynamic> r, Names names) {
    typeId = '${r['disaster_type_id']}';
    brgyId = '${r['barangay_id']}';
    final ids =
        (r['sitio_ids'] as List?) ?? [if (r['sitio_id'] != null) r['sitio_id']];
    sitioRows = ids.isEmpty ? [''] : [for (final i in ids) '$i'];
    desc.text = '${r['description'] ?? ''}';
    families.text = '${r['affected_families'] ?? ''}';
    final rows = [
      for (final n in (r['needs'] as List? ?? const []))
        if (n is Map && n['item_id'] != null) n,
    ];
    if (rows.isNotEmpty) {
      final offered = {for (final i in names.rows('items')) '${i['id']}'};
      needs
        ..clear()
        ..addAll([
          for (final n in rows)
            _Need()
              ..qty.text = '${n['quantity']}'
              // A retired item (e.g. the old gallons water) is no longer
              // in the list: the reporter picks the current one again.
              ..itemId = offered.contains('${n['item_id']}')
                  ? '${n['item_id']}'
                  : null,
        ]);
      _fills++;
      return;
    }
    final parsed = <_Need>[];
    for (final part in '${r['assistance_needed'] ?? ''}'.split(',')) {
      final m = RegExp(r'^\s*(.+?):\s*(\d+)\s*(.*)$').firstMatch(part);
      if (m == null) continue;
      final need = _Need()..qty.text = m.group(2)!;
      final id = _idByName(names, 'items', m.group(1));
      if (id != null) {
        need.itemId = id;
      } else {
        need
          ..itemId = _other
          ..otherName.text = m.group(1)!.trim()
          ..otherUnit.text = m.group(3)!.trim();
      }
      parsed.add(need);
    }
    if (parsed.isNotEmpty) {
      needs
        ..clear()
        ..addAll(parsed);
    }
    _fills++;
  }

  /// Bumped after "Fill from SMS" so the dropdowns rebuild with the new values.
  int _fills = 0;

  /// What could not be filled from the SMS, shown to the Administrator.
  List<String> _fillNotes = const [];

  /// Length of the SMS box the last time it changed, to tell a paste (many
  /// characters at once) from typing.
  int _smsLen = 0;

  /// Problema 2.2: pasting the received SMS fills the form by itself. The
  /// "Fill the form from this SMS" button stays for hand-typed or edited text.
  void _smsChanged(String value, Names names) {
    final grew = value.length - _smsLen;
    _smsLen = value.length;
    if (grew > 15 && value.toUpperCase().contains(smsReportHeader)) {
      _fillFromSms(names, quiet: true);
    }
  }

  /// "Rice (kg)" / " rice " -> "rice"
  static String _norm(String s) => s
      .replaceAll(RegExp(r'\s*\(.*\)$'), '')
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), ' ');

  /// Id of the lookup row whose display name matches [name], or null.
  String? _idByName(Names names, String list, String? name) {
    if (name == null) return null;
    final want = _norm(name);
    for (final r in names.rows(list)) {
      if (_norm(names.of(list, r['id'], fallback: '')) == want) {
        return '${r['id']}';
      }
    }
    return null;
  }

  _Need _needFrom(SmsNeed n, Names names) {
    final need = _Need()..qty.text = '${n.quantity}';
    final id = _idByName(names, 'items', n.item);
    if (id != null) {
      need.itemId = id;
    } else {
      need.itemId = _other;
      need.otherName.text = n.item;
      need.otherUnit.text = n.unit;
    }
    return need;
  }

  /// Reads the pasted SMS (sms_report_format.dart) and fills the form.
  /// Nothing is saved: the Administrator still checks every field and taps
  /// "Encode SMS report" (manual review, Scope 2.4).
  void _fillFromSms(Names names, {bool quiet = false}) {
    final parsed = SmsReport.parse(smsText.text);
    if (parsed == null) {
      if (quiet) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This text is not in the NexaAid SMS format. '
            'Fill in the form by hand.',
          ),
        ),
      );
      return;
    }
    final notes = <String>[
      if (parsed.missing.isNotEmpty)
        'The SMS is missing: ${parsed.missing.join(', ')}.',
      ...parsed.problems,
    ];
    final type = _idByName(names, 'disaster_types', parsed.disasterType);
    if (parsed.disasterType != null && type == null) {
      notes.add(
        'Disaster type "${parsed.disasterType}" not found. Choose it below.',
      );
    }
    final brgy = _idByName(names, 'barangays', parsed.barangay);
    if (parsed.barangay != null && brgy == null) {
      notes.add('Barangay "${parsed.barangay}" not found. Choose it below.');
    }
    final sitios = <String>[];
    if (brgy != null) {
      for (final name in parsed.sitios) {
        final want = _norm(name);
        final match = names
            .rows('sitios')
            .where(
              (st) =>
                  '${st['barangay_id']}' == brgy &&
                  _norm('${st['name']}') == want,
            )
            .firstOrNull;
        if (match == null) {
          notes.add(
            'Sitio "$name" not found in this barangay. Choose it below.',
          );
        } else {
          sitios.add('${match['id']}');
        }
      }
    }
    final newNeeds = [for (final n in parsed.needs) _needFrom(n, names)];
    setState(() {
      typeId = type;
      brgyId = brgy;
      sitioRows = sitios.isEmpty ? [''] : sitios;
      if (parsed.families != null) families.text = '${parsed.families}';
      if (parsed.details != null) desc.text = parsed.details!;
      if (newNeeds.isNotEmpty) {
        needs
          ..clear()
          ..addAll(newNeeds);
      }
      _fillNotes = notes;
      _fills++;
    });
  }

  String _needName(_Need n, Names names) => n.itemId == _other
      ? n.otherName.text.trim()
      : names
            .of('items', n.itemId, fallback: '')
            .replaceAll(RegExp(r'\s*\(.*\)$'), '');

  String _needUnit(_Need n, Names names) {
    if (n.itemId == _other) {
      return normalizeUnit(n.otherUnit.text) ?? n.otherUnit.text.trim();
    }
    for (final i in names.rows('items')) {
      if ('${i['id']}' == n.itemId) return '${i['unit'] ?? ''}';
    }
    return '';
  }

  /// Concerns2 follow-up: the same item can't be listed twice
  /// (it showed up as "Medicine Kit: 1 boxes, Medicine Kit: 2 boxes").
  /// Returns the earlier need number that already has this item, or null.
  int? _duplicateOf(int i) {
    final n = needs[i];
    for (var j = 0; j < i; j++) {
      final o = needs[j];
      if (n.itemId == null || o.itemId != n.itemId) continue;
      if (n.itemId != _other) return j + 1;
      final a = n.otherName.text.trim().toLowerCase();
      if (a.isNotEmpty && a == o.otherName.text.trim().toLowerCase()) {
        return j + 1;
      }
    }
    return null;
  }

  Future<void> _submit(Names names) async {
    if (!_form.currentState!.validate()) return;
    final total = needs.fold<int>(
      0,
      (a, n) => a + int.parse(n.qty.text.trim()),
    );
    if (total > maxEstimatedQuantity) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'All needs together come to ${_withCommas(total)}. '
            'The maximum is ${_withCommas(maxEstimatedQuantity)}.',
          ),
        ),
      );
      return;
    }
    setState(() => busy = true);
    // Per-item fulfillment (Oct 2026): `needs` is one line per item, in the
    // item's own unit, and fulfillment is measured per need. The readable
    // summary "Rice: 50 kg, Drinking Water: 20 L" and the total are still
    // sent for the screens that show them.
    final summary = needs
        .map(
          (n) =>
              '${_needName(n, names)}: ${n.qty.text.trim()} ${_needUnit(n, names)}'
                  .trim(),
        )
        .join(', ');
    final body = {
      'disaster_type_id': int.parse(typeId!),
      'barangay_id': int.parse(brgyId!),
      'sitio_id': _sitioIds.firstOrNull,
      'sitio_ids': _sitioIds,
      'description': desc.text.trim(),
      'affected_families': int.parse(families.text.trim()),
      'assistance_needed': summary,
      'estimated_quantity': total,
      'needs': [
        for (final n in needs)
          if (n.itemId == _other)
            {
              'other_item_name': n.otherName.text.trim(),
              'other_item_unit': _needUnit(n, names),
              'quantity': int.parse(n.qty.text.trim()),
            }
          else
            {
              'item_id': int.parse(n.itemId!),
              'quantity': int.parse(n.qty.text.trim()),
            },
      ],
    };
    if (editing) {
      final r = await act(
        context,
        () => api.put('/reports/${widget.edit!['report_id']}/mine', body: body),
        success: widget.edit!['status'] == 'Rejected'
            ? 'Report corrected and sent back for validation.'
            : 'Report updated. It is still pending validation.',
      );
      if (!mounted) return;
      setState(() => busy = false);
      if (r.ok) Navigator.of(context).pop(true);
      return;
    }
    final r = await act(
      context,
      () => sms
          ? api.post(
              '/reports/sms',
              body: {
                ...body,
                'contact_number': smsSender.text.trim(),
                'raw_message': smsText.text.trim(),
              },
            )
          : api.post('/reports/', body: {...body, 'source': 'Mobile'}),
      success: sms
          ? 'SMS report encoded. It is now pending on the Validate tab.'
          : 'Report submitted. It is now pending admin validation.',
    );
    if (!mounted) return;
    setState(() {
      busy = false;
      if (r.ok) {
        _form.currentState!.reset();
        desc.clear();
        families.clear();
        smsSender.clear();
        smsText.clear();
        _smsLen = 0;
        needs
          ..clear()
          ..add(_Need());
        typeId = brgyId = null;
        sitioRows = [''];
        _fillNotes = const [];
        _fills++;
      }
    });
    if (r.ok) _draft?.clear(); // submitted: the draft is no longer needed
  }

  Widget _needRow(int i, Names names) {
    final n = needs[i];
    final unit = _needUnit(n, names);
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
                  child: DropdownButtonFormField<String>(
                    initialValue: n.itemId,
                    isExpanded: true,
                    decoration: InputDecoration(labelText: 'Need ${i + 1}'),
                    items: [
                      for (final it in names.rows('items'))
                        DropdownMenuItem(
                          value: '${it['id']}',
                          child: Text('${it['item_name'] ?? it['name']}'),
                        ),
                      const DropdownMenuItem(
                        value: _other,
                        child: Text('Other…'),
                      ),
                    ],
                    onChanged: (v) => setState(() => n.itemId = v),
                    validator: (v) {
                      if (v == null) return 'Choose an item';
                      if (v == _other) return null; // checked on the name
                      final dup = _duplicateOf(i);
                      return dup == null
                          ? null
                          : 'Already in Need $dup. Change the amount there.';
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
            if (n.itemId == _other) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: n.otherName,
                      decoration: const InputDecoration(labelText: 'Item'),
                      validator: (v) {
                        if ((v ?? '').trim().isEmpty) return 'Required';
                        final dup = _duplicateOf(i);
                        return dup == null ? null : 'Already in Need $dup';
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    // Testing fix 4.1: same unit list as the donation form.
                    child: QuantityUnitField(
                      controller: n.otherUnit,
                      onChanged: () => setState(() {}),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            TextFormField(
              controller: n.qty,
              keyboardType: TextInputType.number,
              inputFormatters: _wholeNumberInput,
              decoration: InputDecoration(
                labelText: 'How many?',
                suffixText: unit.isEmpty ? null : unit,
              ),
              validator: _wholeNumber(maxEstimatedQuantity),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: api.lookups(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final names = Names(snap.data!);
        if (editing && !_filledFromEdit) {
          _filledFromEdit = true;
          _fillFromReport(widget.edit!, names);
        }
        final sitios = names
            .rows('sitios')
            .where((s) => '${s['barangay_id']}' == brgyId)
            .toList();
        return Form(
          key: _form,
          onChanged: _saveDraft,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              PageHeader(
                editing
                    ? 'Edit Report #${widget.edit!['report_id']}'
                    : sms
                    ? 'Encode SMS Report'
                    : 'Submit Post-Disaster Report',
                subtitle: editing
                    ? (widget.edit!['status'] == 'Rejected'
                          ? 'Rejected: ${widget.edit!['rejection_reason'] ?? ''}\n'
                                'Correct it and save to send it back for validation.'
                          : 'You can change it until the Administrator validates it.')
                    : sms
                    ? 'Paste the text the Disaster Unit sent, tap Fill, then '
                          'check every field before saving. It is saved as '
                          'Pending; validate it on the Validate tab.'
                    : 'Saved as Pending until the Administrator validates it. '
                          'No internet? Use the SMS report tab to text it to '
                          'the Administrator.',
              ),
              if (sms) ...[
                const SectionTitle('SMS as received'),
                TextFormField(
                  controller: smsSender,
                  keyboardType: TextInputType.phone,
                  // Same as the GCash field: digits only, stops at 11.
                  inputFormatters: phoneFormatters,
                  decoration: const InputDecoration(
                    labelText: 'Sender number',
                    hintText: '09XXXXXXXXX',
                    helperText: 'PH mobile number, 11 digits',
                  ),
                  validator: (v) {
                    final n = (v ?? '').trim();
                    if (n.isEmpty) return 'Required';
                    return RegExp(r'^09\d{9}$').hasMatch(n)
                        ? null
                        : 'Mobile number, 11 digits, e.g. 09171234567';
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: smsText,
                  minLines: 4,
                  maxLines: 10,
                  onChanged: (v) => _smsChanged(v, names),
                  decoration: const InputDecoration(
                    labelText: 'SMS text (paste it exactly as received)',
                    helperText:
                        'Paste the text and the form below fills itself in.',
                    hintText: 'NEXAAID REPORT\nTYPE: ...\nBRGY: ...',
                  ),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'Required' : null,
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton.icon(
                    onPressed: () => _fillFromSms(names),
                    icon: const Icon(Icons.auto_fix_high),
                    label: const Text('Fill the form from this SMS'),
                  ),
                ),
                if (_fillNotes.isNotEmpty)
                  Card(
                    margin: const EdgeInsets.only(top: 8),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final note in _fillNotes)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Icon(Icons.warning_amber, size: 18),
                                  const SizedBox(width: 6),
                                  Expanded(child: Text(note)),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
              const SectionTitle('Disaster and location'),
              LookupDropdown(
                key: ValueKey('type-$_fills'),
                list: 'disaster_types',
                label: 'Disaster type',
                value: typeId,
                names: names,
                onChanged: (v) => setState(() => typeId = v),
              ),
              const SizedBox(height: 12),
              LookupDropdown(
                key: ValueKey('brgy-$_fills'),
                list: 'barangays',
                label: 'Barangay',
                value: brgyId,
                names: names,
                onChanged: (v) => setState(() {
                  brgyId = v;
                  sitioRows = [''];
                }),
              ),
              // Concerns2: the sitio field only appears after a barangay is
              // chosen, lists only that barangay's sitios, and defaults to
              // the whole barangay. problema_napud 2.2: "Add another sitio".
              if (brgyId != null) ...[
                const SizedBox(height: 12),
                SitioPicker(
                  key: ValueKey('sitios-$brgyId-$_fills'),
                  options: {
                    for (final st in sitios) '${st['id']}': '${st['name']}',
                  },
                  rows: sitioRows,
                  onChanged: (rows) => setState(() => sitioRows = rows),
                ),
              ],
              const SectionTitle('Donation info'),
              NewReportDonationInfo(barangayId: brgyId),
              const SectionTitle('Situation (DROMIC)'),
              TextFormField(
                controller: desc,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Short incident description',
                ),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: families,
                keyboardType: TextInputType.number,
                inputFormatters: _wholeNumberInput,
                decoration: InputDecoration(
                  labelText: 'Affected families',
                  helperText:
                      'Numbers only, up to ${_withCommas(maxAffectedFamilies)}',
                ),
                validator: _wholeNumber(maxAffectedFamilies),
              ),
              SectionTitle(
                'Assistance needed',
                trailing: TextButton.icon(
                  onPressed: () {
                    setState(() => needs.add(_Need()));
                    _saveDraft();
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('Add need'),
                ),
              ),
              for (var i = 0; i < needs.length; i++) _needRow(i, names),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: busy ? null : () => _submit(names),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                ),
                icon: Icon(
                  editing
                      ? Icons.check
                      : sms
                      ? Icons.sms_outlined
                      : Icons.send,
                ),
                label: Text(
                  editing
                      ? 'Save changes'
                      : sms
                      ? 'Encode SMS report'
                      : 'Submit report',
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Appendix H 3.3 Priority-based report filtering.
class PriorityChips extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const PriorityChips({
    super.key,
    required this.value,
    required this.onChanged,
  });

  static const levels = [
    '',
    'Critical',
    'High',
    'Medium',
    'Low',
    'Needs Review',
  ];

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final p in levels)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(p.isEmpty ? 'All priorities' : p),
                selected: value == p,
                onSelected: (_) => onChanged(p),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Appendix H 2.4 View validated reports (every role), with 3.3
// priority-based filtering for the roles that have it.
// ---------------------------------------------------------------------------
class ValidatedReportsScreen extends StatefulWidget {
  /// Show the priority filter (Admin, donors, CSWS Main Office and
  /// Disaster Unit in Appendix H 3.3).
  final bool filter;
  final bool header;
  const ValidatedReportsScreen({
    super.key,
    this.filter = false,
    this.header = true,
  });

  @override
  State<ValidatedReportsScreen> createState() => _ValidatedReportsScreenState();
}

class _ValidatedReportsScreenState extends State<ValidatedReportsScreen> {
  String priority = '';
  String? progress; // fulfillment status, null = any (Ivan's note)
  ReportSort sort = ReportSort.urgent;

  @override
  Widget build(BuildContext context) {
    return Loader(
      key: ValueKey(priority),
      load: [
        () => api.get(
          '/reports/validated',
          query: {if (priority.isNotEmpty) 'priority_level': priority},
        ),
        api.lookupsResult,
      ],
      builder: (context, data) {
        final all = (data[0] as List).cast<Map<String, dynamic>>();
        final names = Names(Map<String, dynamic>.from(data[1] as Map));
        final rows = sortAndFilterReports(
          all,
          fulfillment: progress,
          sort: sort,
        );
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (widget.header)
              PageHeader(
                'Validated Reports',
                subtitle:
                    'Reports approved by the Administrator • ${roleLine()}',
              ),
            if (widget.filter) ...[
              PriorityChips(
                value: priority,
                onChanged: (p) => setState(() => priority = p),
              ),
              const SizedBox(height: 8),
            ],
            // Fulfillment status filter and sort for every role, also the
            // ones without priority filtering (Ivan's note: "for every user
            // that has this dashboard"; fulfilled reports are found with the
            // Fulfilled chip, there is no separate Done section).
            FulfillmentChips(
              rows: all,
              value: progress,
              onChanged: (v) => setState(() => progress = v),
            ),
            const SizedBox(height: 12),
            ReportSortField(
              value: sort,
              onChanged: (v) => setState(() => sort = v),
            ),
            const SizedBox(height: 12),
            if (rows.isEmpty) const EmptyState('No validated reports to show.'),
            for (final r in rows) ReportCard(r, names),
          ],
        );
      },
    );
  }
}

/// Reports menu for CSWS Main Office and Disaster Unit: validated reports
/// (2.4) and report status monitoring (2.5), both with priority filters.
class ReportsHub extends StatefulWidget {
  const ReportsHub({super.key});

  @override
  State<ReportsHub> createState() => _ReportsHubState();
}

class _ReportsHubState extends State<ReportsHub>
    with HomeTargetListener<ReportsHub> {
  bool monitor = false;

  // A notification about a report opens Reports > Validated or Status.
  @override
  String get homeTab => 'Reports';

  @override
  void applyHomeTarget(HomeTarget target) {
    if (target.view == 'status') monitor = true;
    if (target.view == 'validated') monitor = false;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: false,
                icon: Icon(Icons.verified_outlined),
                label: Text('Validated'),
              ),
              ButtonSegment(
                value: true,
                icon: Icon(Icons.monitor_heart_outlined),
                label: Text('Status'),
              ),
            ],
            selected: {monitor},
            onSelectionChanged: (v) => setState(() => monitor = v.first),
          ),
        ),
        Expanded(
          child: monitor
              ? const MonitoringScreen()
              : const ValidatedReportsScreen(filter: true),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Appendix H 2.5 Monitor report status (Admin, CSWS Main Office,
// CSWS Disaster Unit): every report with its fulfillment progress.
// ---------------------------------------------------------------------------
class MonitoringScreen extends StatefulWidget {
  const MonitoringScreen({super.key});

  @override
  State<MonitoringScreen> createState() => _MonitoringScreenState();
}

class _MonitoringScreenState extends State<MonitoringScreen> {
  String priority = '';
  String? progress; // fulfillment status, null = any (Ivan's note)
  ReportSort sort = ReportSort.urgent;
  bool onlyMine = false;
  int _loads = 0;

  // Oct 11 (Daniel): the CSWS Disaster Unit edits or withdraws its own
  // reports here until the Administrator validates them.
  bool get _reporter => api.role == Roles.cswsUnit;

  Future<void> _edit(Map<String, dynamic> r) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Edit report')),
          body: NewReportScreen(edit: r),
        ),
      ),
    );
    if (saved == true && mounted) setState(() => _loads++);
  }

  Future<void> _withdraw(Map<String, dynamic> r) async {
    final v = await formDialog(
      context,
      title: 'Withdraw report #${r['report_id']}?',
      message:
          'It will not be validated or shown to donors. It stays in your '
          'list as Cancelled.',
      fields: const [
        DialogField(
          'reason',
          'Reason (optional)',
          required: false,
          multiline: true,
          hint: 'e.g. Sent twice, or wrong barangay',
        ),
      ],
      confirm: 'Withdraw',
    );
    if (v == null || !mounted) return;
    final res = await act(
      context,
      () => api.post(
        '/reports/${r['report_id']}/withdraw',
        body: {if (v['reason']!.isNotEmpty) 'reason': v['reason']},
      ),
      success: 'Report #${r['report_id']} withdrawn',
    );
    if (res.ok && mounted) setState(() => _loads++);
  }

  @override
  Widget build(BuildContext context) {
    return Loader(
      key: ValueKey('$priority/$_loads'),
      load: [
        () => api.get(
          '/reports/monitoring',
          query: {if (priority.isNotEmpty) 'priority_level': priority},
        ),
        api.lookupsResult,
        if (_reporter) () => api.get('/reports/mine'),
      ],
      builder: (context, data) {
        final names = Names(Map<String, dynamic>.from(data[1] as Map));
        final mine = _reporter
            ? {
                for (final r in (data[2] as List).cast<Map>())
                  r['report_id'] as int,
              }
            : <int>{};
        final all = (data[0] as List).cast<Map<String, dynamic>>();
        bool editable(Map r) =>
            mine.contains(r['report_id']) &&
            (r['status'] == 'Pending' || r['status'] == 'Rejected');
        final sorted = sortAndFilterReports(
          onlyMine
              ? all.where((r) => mine.contains(r['report_id'])).toList()
              : all,
          fulfillment: progress,
          sort: sort,
        );
        // My own reports that can still be edited come first.
        final rows = onlyMine
            ? [...sorted.where(editable), ...sorted.where((r) => !editable(r))]
            : sorted;
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            PageHeader(
              'Report Status',
              subtitle:
                  'Fulfillment progress of every report, active and done • '
                  '${roleLine()}',
            ),
            PriorityChips(
              value: priority,
              onChanged: (p) => setState(() => priority = p),
            ),
            const SizedBox(height: 8),
            FulfillmentChips(
              rows: all,
              value: progress,
              onChanged: (v) => setState(() => progress = v),
            ),
            const SizedBox(height: 12),
            ReportSortField(
              value: sort,
              onChanged: (v) => setState(() => sort = v),
            ),
            if (_reporter) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: FilterChip(
                  avatar: const Icon(Icons.person_outline, size: 18),
                  label: Text('Only my reports (${mine.length})'),
                  selected: onlyMine,
                  onSelected: (v) => setState(() => onlyMine = v),
                ),
              ),
            ],
            const SizedBox(height: 12),
            if (rows.isEmpty) const EmptyState('No reports to show.'),
            for (final r in rows)
              ReportCard(
                r,
                names,
                actions: editable(r)
                    ? [
                        TextButton.icon(
                          onPressed: () => _withdraw(r),
                          style: TextButton.styleFrom(
                            foregroundColor: AppColors.danger,
                          ),
                          icon: const Icon(Icons.block, size: 18),
                          label: const Text('Withdraw'),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: () => _edit(r),
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          label: Text(
                            r['status'] == 'Rejected'
                                ? 'Fix and resend'
                                : 'Edit',
                          ),
                        ),
                      ]
                    : const [],
              ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// UC-A3 Process reports (Administrator)
// ---------------------------------------------------------------------------
class AdminReportsScreen extends StatefulWidget {
  const AdminReportsScreen({super.key});

  @override
  State<AdminReportsScreen> createState() => _AdminReportsScreenState();
}

class _AdminReportsScreenState extends State<AdminReportsScreen>
    with HomeTargetListener<AdminReportsScreen> {
  String status = 'Pending';
  String priority = '';
  String? progress; // fulfillment status in the Validated view
  ReportSort sort = ReportSort.urgent;
  int _loads = 0;
  int? _highlight; // report the notification is about, shown first

  @override
  String get homeTab => 'Validate';

  @override
  void applyHomeTarget(HomeTarget target) {
    if (const ['Pending', 'Validated', 'Rejected'].contains(target.view)) {
      status = target.view!;
    }
    _highlight = target.id;
    _loads++;
  }

  Future<void> _reject(Map<String, dynamic> r) async {
    final v = await formDialog(
      context,
      title: 'Reject report #${r['report_id']}',
      message: 'The reason is sent back so the report can be corrected.',
      fields: const [DialogField('reason', 'Reason', multiline: true)],
      confirm: 'Reject',
    );
    if (v == null || !mounted) return;
    await act(
      context,
      () => api.post(
        '/reports/${r['report_id']}/reject',
        body: {'rejection_reason': v['reason']},
      ),
      success: 'Report #${r['report_id']} rejected',
    );
  }

  /// Testing 2.3: the Administrator deletes a Rejected report. The server
  /// keeps the row for the audit trail and hides it from every list.
  Future<void> _delete(Map<String, dynamic> r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete report #${r['report_id']}?'),
        content: const Text(
          'It disappears from every list. The rejection and who made it '
          'stay in the audit log.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep report'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await act(
      context,
      () => api.delete('/reports/${r['report_id']}'),
      success: 'Report #${r['report_id']} deleted',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Loader(
      key: ValueKey('$status/$priority/$_loads'),
      load: [
        // Validated reports come with their fulfillment progress, for the
        // fulfillment chips and sort (Ivan's note).
        () => status == 'Validated'
            ? api.get(
                '/reports/validated',
                query: {if (priority.isNotEmpty) 'priority_level': priority},
              )
            : api.get('/reports/', query: {'status': status}),
        api.lookupsResult,
      ],
      builder: (context, data) {
        final all = (data[0] as List).cast<Map<String, dynamic>>();
        final rows = status == 'Validated'
            ? sortAndFilterReports(all, fulfillment: progress, sort: sort)
            : all;
        // The report a notification pointed at comes first, outlined.
        final hi = rows.indexWhere((r) => r['report_id'] == _highlight);
        if (hi > 0) rows.insert(0, rows.removeAt(hi));
        final names = Names(Map<String, dynamic>.from(data[1] as Map));
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            PageHeader('Report Validation', subtitle: roleLine()),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'Pending', label: Text('Pending')),
                ButtonSegment(value: 'Validated', label: Text('Validated')),
                ButtonSegment(value: 'Rejected', label: Text('Rejected')),
              ],
              selected: {status},
              onSelectionChanged: (s) => setState(() => status = s.first),
            ),
            const SizedBox(height: 12),
            if (status == 'Validated') ...[
              PriorityChips(
                value: priority,
                onChanged: (p) => setState(() => priority = p),
              ),
              const SizedBox(height: 8),
              FulfillmentChips(
                rows: all,
                value: progress,
                onChanged: (v) => setState(() => progress = v),
              ),
              const SizedBox(height: 12),
              ReportSortField(
                value: sort,
                onChanged: (v) => setState(() => sort = v),
              ),
              const SizedBox(height: 12),
            ],
            if (rows.isEmpty) EmptyState('No ${status.toLowerCase()} reports.'),
            for (final r in rows)
              ReportCard(
                r,
                names,
                highlighted: r['report_id'] == _highlight,
                actions: status == 'Pending'
                    ? [
                        OutlinedButton(
                          onPressed: () => _reject(r),
                          child: const Text('Reject'),
                        ),
                        FilledButton.icon(
                          onPressed: () => act(
                            context,
                            () =>
                                api.post('/reports/${r['report_id']}/validate'),
                            success:
                                'Report #${r['report_id']} validated and published to donors',
                          ),
                          icon: const Icon(Icons.check),
                          label: const Text('Validate'),
                        ),
                      ]
                    : status == 'Rejected'
                    ? [
                        OutlinedButton.icon(
                          onPressed: () => _delete(r),
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('Delete'),
                        ),
                      ]
                    : const [],
              ),
          ],
        );
      },
    );
  }
}

// UC-A1 account creation moved to account_form.dart (AccountsScreen).

// ---------------------------------------------------------------------------
// Dashboards (UC-A4, UC-CD2, UC-CM3, UC-B2)
// ---------------------------------------------------------------------------
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [
        () => api.get('/dashboard/summary'),
        () => api.get('/dashboard/reports-breakdown'),
        () => api.get('/dashboard/fulfillment'),
        () => api.get('/dashboard/logistics'),
      ],
      builder: (context, d) {
        final s = d[0] as Map,
            b = d[1] as Map,
            f = d[2] as Map,
            l = d[3] as Map;
        Widget bars(
          String title,
          List rows,
          String key,
          Color Function(String?) tone,
        ) {
          final total = rows.fold<int>(0, (a, r) => a + (r['count'] as int));
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  if (rows.isEmpty) const Text('No data yet'),
                  for (final r in rows)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 100,
                            child: Text('${r[key] ?? 'None'}'),
                          ),
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: total == 0 ? 0 : r['count'] / total,
                                minHeight: 10,
                                color: tone(r[key] as String?),
                                backgroundColor: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 36,
                            child: Text(
                              '${r['count']}',
                              textAlign: TextAlign.right,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          );
        }

        // 9.3 (testing): the cards open what is behind the number.
        void reportStatus() =>
            HomeNav.go(context, const HomeTarget('Reports', view: 'status'));
        void sheet(String title, List rows) => showModalBottomSheet<void>(
          context: context,
          showDragHandle: true,
          builder: (_) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: bars(title, rows, 'status', statusTone),
            ),
          ),
        );

        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            PageHeader(
              '${api.role ?? 'System'} Dashboard',
              subtitle: roleLine(),
            ),
            StatCardGrid([
              StatCard(
                // Rejected and withdrawn reports are not counted (backend).
                label: 'Disaster reports',
                value: '${s['total_reports']}',
                icon: Icons.report_outlined,
                onTap: reportStatus,
              ),
              StatCard(
                label: 'Physical donations',
                value: '${s['total_donations']}',
                icon: Icons.volunteer_activism_outlined,
              ),
              StatCard(
                label: 'Deliveries',
                value: '${s['total_deliveries']}',
                icon: Icons.local_shipping_outlined,
                // The Disaster Unit has no delivery list (Appendix H 8.5):
                // show the deliveries by status.
                onTap: () => sheet(
                  'Deliveries by status',
                  l['deliveries_by_status'] as List,
                ),
              ),
              StatCard(
                label: 'Logistics requests',
                value: '${s['total_logistics_requests']}',
                icon: Icons.fire_truck_outlined,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: const Text('Logistics requests')),
                      body: const SupportRecordsScreen(),
                    ),
                  ),
                ),
              ),
              StatCard(
                label: 'Average fulfillment',
                value:
                    '${(f['average_fulfillment_percentage'] as num).toStringAsFixed(0)}%',
                icon: Icons.pie_chart_outline,
                color: AppColors.success,
                onTap: reportStatus,
              ),
              StatCard(
                label: 'Est. value of donations',
                value: pesos(b['total_estimated_value']) ?? 'PHP 0',
                icon: Icons.payments_outlined,
              ),
            ]),
            const SizedBox(height: 12),
            bars(
              'Reports by status',
              b['by_status'] as List,
              'status',
              statusTone,
            ),
            bars(
              'Reports by priority',
              b['by_priority'] as List,
              'priority_level',
              priorityTone,
            ),
            bars(
              'Deliveries by status',
              l['deliveries_by_status'] as List,
              'status',
              statusTone,
            ),
            bars(
              'Logistics requests by status',
              l['requests_by_status'] as List,
              'status',
              statusTone,
            ),
          ],
        );
      },
    );
  }
}
