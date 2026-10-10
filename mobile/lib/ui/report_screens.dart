import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import 'donation_info.dart' show NewReportDonationInfo;
import 'input_formatters.dart';
import 'report_filters.dart';
import 'sms_report_format.dart';
import 'widgets.dart';

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

/// Card for one disaster report (with fulfillment if available).
class ReportCard extends StatelessWidget {
  final Map<String, dynamic> r;
  final Names names;
  final List<Widget> actions;
  const ReportCard(this.r, this.names, {super.key, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    final type = names.of('disaster_types', r['disaster_type_id']);
    final brgy = names.of('barangays', r['barangay_id']);
    final hasFulfillment = r['total_items_needed'] != null;
    // Appendix H 3.2: every role except DRRMO views priority guidance.
    final showPriority = api.role != Roles.drrmo;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '#${r['report_id']}  $type in $brgy',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Badge2.status(r['status'] as String?),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (showPriority && r['priority_level'] != null)
                  Badge2.priority(r['priority_level'] as String?),
                Badge2(
                  'via ${r['source']}',
                  Colors.blueGrey,
                  icon: Icons.input,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              [
                if (r['affected_families'] != null)
                  '${r['affected_families']} families',
                if (r['assistance_needed'] != null)
                  'Needs: ${r['assistance_needed']}',
                if (r['estimated_quantity'] != null)
                  'Qty: ${r['estimated_quantity']}',
              ].join('  ·  '),
            ),
            if (r['description'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${r['description']}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (showPriority &&
                (r['priority_guidance'] ?? r['ai_recommendation']) != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.auto_awesome,
                      size: 16,
                      color: Colors.deepPurple,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'AI guidance: ${r['priority_guidance'] ?? r['ai_recommendation']}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            if (r['rejection_reason'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Rejected: ${r['rejection_reason']}',
                  style: const TextStyle(color: Color(0xFFC62828)),
                ),
              ),
            if (hasFulfillment) ...[
              const SizedBox(height: 10),
              Progress(
                delivered: r['total_items_delivered'] as num? ?? 0,
                needed: r['total_items_needed'] as num? ?? 0,
                percent: num.tryParse('${r['fulfillment_percentage']}'),
              ),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  for (final a in actions)
                    Padding(padding: const EdgeInsets.only(left: 8), child: a),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// UC-CD1 Submit post-disaster report (CSWS Disaster Unit), and
// UC-A3 alt 8a Encode SMS report (Administrator, smsEncode: true).
// Scope 2.4: the Disaster Unit SENDS structured SMS reports (see
// sms_send_screen.dart); the Administrator reviews and ENCODES them here.
// ---------------------------------------------------------------------------
class NewReportScreen extends StatefulWidget {
  /// true = Administrator encoding a received SMS report (UC-A3 8a).
  final bool smsEncode;
  const NewReportScreen({super.key, this.smsEncode = false});

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
  String? typeId, brgyId, sitioId;
  final desc = TextEditingController();
  final families = TextEditingController();
  final smsSender = TextEditingController();
  final smsText = TextEditingController();
  final needs = <_Need>[_Need()];
  bool busy = false;

  /// true when encoding a report that arrived by SMS (UC-A3 8a).
  late final bool sms = widget.smsEncode;

  /// Bumped after "Fill from SMS" so the dropdowns rebuild with the new values.
  int _fills = 0;

  /// What could not be filled from the SMS, shown to the Administrator.
  List<String> _fillNotes = const [];

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
  void _fillFromSms(Names names) {
    final parsed = SmsReport.parse(smsText.text);
    if (parsed == null) {
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
    String? sitio;
    if (brgy != null && parsed.sitio != null) {
      final want = _norm(parsed.sitio!);
      for (final st in names.rows('sitios')) {
        if ('${st['barangay_id']}' == brgy && _norm('${st['name']}') == want) {
          sitio = '${st['id']}';
          break;
        }
      }
      if (sitio == null) {
        notes.add(
          'Sitio "${parsed.sitio}" not found in this barangay. Choose it below.',
        );
      }
    }
    final newNeeds = [for (final n in parsed.needs) _needFrom(n, names)];
    setState(() {
      typeId = type;
      brgyId = brgy;
      sitioId = sitio;
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
    if (n.itemId == _other) return n.otherUnit.text.trim();
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
    // The report table has one text field for the needs and one total
    // quantity, so the list is stored as "Rice: 50 kg, Drinking Water: 20 gallons".
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
      'sitio_id': (sitioId ?? '').isEmpty ? null : int.parse(sitioId!),
      'description': desc.text.trim(),
      'affected_families': int.parse(families.text.trim()),
      'assistance_needed': summary,
      'estimated_quantity': total,
    };
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
          ? 'SMS report encoded and saved as Pending. Validate it under Validate.'
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
        needs
          ..clear()
          ..add(_Need());
        typeId = brgyId = sitioId = null;
        _fillNotes = const [];
        _fills++;
      }
    });
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
                    onPressed: () => setState(() => needs.removeAt(i)),
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
                    child: TextFormField(
                      controller: n.otherUnit,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Unit',
                        hintText: 'pcs, boxes',
                      ),
                      validator: (v) =>
                          (v ?? '').trim().isEmpty ? 'Required' : null,
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
        final sitios = names
            .rows('sitios')
            .where((s) => '${s['barangay_id']}' == brgyId)
            .toList();
        return Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              PageHeader(
                sms ? 'Encode SMS Report' : 'Submit Post-Disaster Report',
                subtitle: sms
                    ? 'Paste the text the CSWS Disaster Unit sent, tap Fill, '
                          'then check every field before saving. '
                          'It is saved as Pending; validate it under Validate.'
                    : 'Saved as Pending until the Administrator validates it. '
                          'No internet? Use the SMS report tab.',
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
                  decoration: const InputDecoration(
                    labelText: 'SMS text (paste it exactly as received)',
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
                  sitioId = null;
                }),
              ),
              // Concerns2: the sitio field only appears after a barangay is
              // chosen, and defaults to the whole barangay.
              if (brgyId != null) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: ValueKey('sitio-$brgyId-$_fills'),
                  initialValue: sitioId ?? '',
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(
                      value: '',
                      child: Text('Whole barangay'),
                    ),
                    for (final s in sitios)
                      DropdownMenuItem(
                        value: '${s['id']}',
                        child: Text('${s['name']}'),
                      ),
                  ],
                  onChanged: (v) => sitioId = v,
                  decoration: const InputDecoration(
                    labelText: 'Sitio',
                    helperText: 'Choose a sitio, or keep Whole barangay',
                  ),
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
                  onPressed: () => setState(() => needs.add(_Need())),
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
                icon: Icon(sms ? Icons.sms_outlined : Icons.send),
                label: Text(sms ? 'Encode SMS report' : 'Submit report'),
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
              // Fulfillment status filter and sort (Ivan's note: for every
              // user that has this dashboard).
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

class _ReportsHubState extends State<ReportsHub> {
  bool monitor = false;

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

  @override
  Widget build(BuildContext context) {
    return Loader(
      key: ValueKey(priority),
      load: [
        () => api.get(
          '/reports/monitoring',
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
            const SizedBox(height: 12),
            if (rows.isEmpty) const EmptyState('No reports to show.'),
            for (final r in rows) ReportCard(r, names),
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

class _AdminReportsScreenState extends State<AdminReportsScreen> {
  String status = 'Pending';
  String priority = '';
  int _loads = 0;

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

  @override
  Widget build(BuildContext context) {
    return Loader(
      key: ValueKey('$status/$priority/$_loads'),
      load: [
        () => api.get(
          '/reports/',
          query: {
            'status': status,
            if (status == 'Validated' && priority.isNotEmpty)
              'priority_level': priority,
          },
        ),
        api.lookupsResult,
      ],
      builder: (context, data) {
        final rows = (data[0] as List).cast<Map<String, dynamic>>();
        final names = Names(Map<String, dynamic>.from(data[1] as Map));
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            PageHeader('Report Validation', subtitle: roleLine()),
            // UC-A3 alt 8a: the Administrator encodes SMS reports.
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => Scaffold(
                        appBar: AppBar(title: const Text('Encode SMS report')),
                        body: const NewReportScreen(smsEncode: true),
                      ),
                    ),
                  );
                  if (mounted) setState(() => _loads++); // reload the list
                },
                icon: const Icon(Icons.sms_outlined),
                label: const Text('Encode SMS report'),
              ),
            ),
            const SizedBox(height: 8),
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
              const SizedBox(height: 12),
            ],
            if (rows.isEmpty) EmptyState('No ${status.toLowerCase()} reports.'),
            for (final r in rows)
              ReportCard(
                r,
                names,
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
                                backgroundColor: Colors.black12,
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

        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            PageHeader(
              '${api.role ?? 'System'} Dashboard',
              subtitle: roleLine(),
            ),
            StatGrid([
              StatTile(
                'Disaster reports',
                '${s['total_reports']}',
                Icons.report_outlined,
              ),
              StatTile(
                'Physical donations',
                '${s['total_donations']}',
                Icons.volunteer_activism_outlined,
              ),
              StatTile(
                'Deliveries',
                '${s['total_deliveries']}',
                Icons.local_shipping_outlined,
              ),
              StatTile(
                'Logistics requests',
                '${s['total_logistics_requests']}',
                Icons.fire_truck_outlined,
              ),
              StatTile(
                'Average fulfillment',
                '${(f['average_fulfillment_percentage'] as num).toStringAsFixed(0)}%',
                Icons.pie_chart_outline,
                color: const Color(0xFF2E7D32),
              ),
              StatTile(
                'Est. value of donations',
                'PHP ${(b['total_estimated_value'] as num).toStringAsFixed(0)}',
                Icons.payments_outlined,
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
