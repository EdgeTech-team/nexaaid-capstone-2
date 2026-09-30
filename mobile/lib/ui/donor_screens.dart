import 'dart:convert';

import 'package:flutter/material.dart';

import 'widgets.dart';

/// UC-D2 / UC-R2 step 1-3: browse validated reports and pick one to
/// support. Layout follows the "Validated Disaster Reports" wireframe.
class ReportsFeed extends StatefulWidget {
  const ReportsFeed({super.key});

  @override
  State<ReportsFeed> createState() => _ReportsFeedState();
}

class _ReportsFeedState extends State<ReportsFeed> {
  String search = '';
  String? barangay, type, priority;

  Widget _filter(
    String hint,
    String? value,
    List<String> options,
    ValueChanged<String?> onChanged,
  ) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
      ),
      items: [
        DropdownMenuItem<String>(value: null, child: Text(hint)),
        for (final o in options) DropdownMenuItem(value: o, child: Text(o)),
      ],
      onChanged: onChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [api.lookupsResult],
      builder: (context, data) {
        final names = Names(Map<String, dynamic>.from(data[0] as Map));
        final all = names.rows('validated_reports');
        final q = search.toLowerCase();
        final reports = all.where((r) {
          final text = [
            r['barangay'],
            r['sitio'],
            r['disaster'],
            r['assistance_needed'],
            r['description'],
          ].join(' ').toLowerCase();
          return (q.isEmpty || text.contains(q)) &&
              (barangay == null || r['barangay'] == barangay) &&
              (type == null || r['disaster'] == type) &&
              (priority == null || r['priority_level'] == priority);
        }).toList();
        return ListView(
          padding: EdgeInsets.zero,
          children: [
            Container(
              width: double.infinity,
              color: Brand.pinkSoft,
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Validated Disaster Reports',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: Brand.ink,
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'Browse and support relief efforts for validated disaster '
                    'reports in Mandaue City',
                    style: TextStyle(color: Brand.muted),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  StatGrid([
                    StatTile(
                      'Validated reports',
                      '${all.length}',
                      Icons.report_outlined,
                    ),
                    StatTile(
                      'High / critical priority',
                      '${all.where((r) => r['priority_level'] == 'High' || r['priority_level'] == 'Critical').length}',
                      Icons.trending_up,
                      color: const Color(0xFFE65100),
                    ),
                  ]),
                  const SizedBox(height: 14),
                  TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText:
                          'Search reports, barangay, or assistance needed...',
                    ),
                    onChanged: (v) => setState(() => search = v.trim()),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _filter('All Barangays', barangay, [
                          for (final b in names.rows('barangays'))
                            '${b['name']}',
                        ], (v) => setState(() => barangay = v)),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _filter('All Types', type, [
                          for (final t in names.rows('disaster_types'))
                            '${t['name']}',
                        ], (v) => setState(() => type = v)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _filter('All Priorities', priority, const [
                    'Critical',
                    'High',
                    'Medium',
                    'Low',
                    'Needs Review',
                  ], (v) => setState(() => priority = v)),
                  const SizedBox(height: 14),
                  Text.rich(
                    TextSpan(
                      text: 'Showing ',
                      style: const TextStyle(color: Brand.muted),
                      children: [
                        TextSpan(
                          text: '${reports.length}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Brand.ink,
                          ),
                        ),
                        const TextSpan(text: ' reports'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (reports.isEmpty)
                    const EmptyState('No validated reports match.'),
                  for (final r in reports) _card(context, r, names),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _card(BuildContext context, Map<String, dynamic> r, Names names) {
    final pct = (r['fulfillment_percentage'] as num? ?? 0).toDouble();
    final state = pct >= 100
        ? 'Fulfilled'
        : pct > 0
        ? 'In Progress'
        : 'Not Started';
    Widget info(String label, dynamic value) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label:',
            style: const TextStyle(fontSize: 12, color: Brand.muted),
          ),
          Text('${value ?? '-'}', style: const TextStyle(fontSize: 14)),
        ],
      ),
    );
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    '${r['disaster']} in Barangay ${r['barangay']}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Badge2.priority(r['priority_level'] as String?),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                info('Barangay', r['barangay']),
                info('Sitio', r['sitio']),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                info('Type', r['disaster']),
                info(
                  'Affected',
                  r['affected_families'] == null
                      ? null
                      : '${r['affected_families']} families',
                ),
              ],
            ),
            if (r['description'] != null) ...[
              const SizedBox(height: 10),
              Text('${r['description']}'),
            ],
            const SizedBox(height: 8),
            Text.rich(
              TextSpan(
                text: 'Assistance Needed: ',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
                children: [
                  TextSpan(
                    text: '${r['assistance_needed'] ?? '-'}',
                    style: const TextStyle(fontWeight: FontWeight.normal),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Progress(
              delivered: r['total_items_delivered'] as num? ?? 0,
              needed: r['total_items_needed'] as num? ?? 0,
              percent: pct,
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 5),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: statusTone(
                  state == 'Fulfilled'
                      ? 'Complete'
                      : state == 'In Progress'
                      ? 'Partial'
                      : null,
                ).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                state,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: statusTone(
                    state == 'Fulfilled'
                        ? 'Complete'
                        : state == 'In Progress'
                        ? 'Partial'
                        : null,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => DonateScreen(report: r, names: names),
                ),
              ),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
              ),
              child: const Text('Donate'),
            ),
          ],
        ),
      ),
    );
  }
}

// Drop-off location shown when "Drop Off" is chosen (manuscript UC-D2 7b:
// "the system shows storage details"). PLACEHOLDER: replace with the real
// CSWS Main Office storage address and hours.
const storageAddress = 'CSWS Main Office storage area, Mandaue City';
const storageHours = 'Monday to Friday, 8:00 AM to 5:00 PM';

// Packaging options (manuscript 3.1: "packaging size, based on the
// available packaging options shown in the system"; data dictionary
// example "50kg sack").
const packagingOptions = [
  'Sack (50 kg)',
  'Sack (25 kg)',
  'Box',
  'Pack',
  'Plastic bag',
  'Bottle',
  'Gallon container',
  'Loose / no packaging',
  'Other',
];

const _otherItem = 'other';

/// One item line on the donation form.
class _Line {
  String? itemId;
  String packaging = packagingOptions.first;
  final qty = TextEditingController();
  final value = TextEditingController();
  final otherName = TextEditingController();
  final otherUnit = TextEditingController();
  final otherPackaging = TextEditingController();
}

/// UC-D2 step 5-6: physical donation form (one or more items), then the
/// QR receipt for each item.
class DonateScreen extends StatefulWidget {
  final Map<String, dynamic> report;
  final Names names;
  const DonateScreen({super.key, required this.report, required this.names});

  @override
  State<DonateScreen> createState() => _DonateScreenState();
}

class _DonateScreenState extends State<DonateScreen> {
  final _form = GlobalKey<FormState>();
  final lines = <_Line>[_Line()];
  String handover = 'Drop Off';
  bool useSavedAddress = true;
  String? savedAddress; // organization address, if the account has one
  final address = TextEditingController();
  final guestName = TextEditingController();
  final guestPhone = TextEditingController();
  bool busy = false;

  @override
  void initState() {
    super.initState();
    if (api.loggedIn) {
      api.get('/donations/mine').then((r) {
        if (!mounted) return;
        String? a;
        if (r.ok) a = r.json['profile']?['address'] as String?;
        setState(() {
          savedAddress = (a ?? '').trim().isEmpty ? null : a;
          useSavedAddress = savedAddress != null;
        });
      });
    }
  }

  String? _req(String? v) => (v ?? '').trim().isEmpty ? 'Required' : null;

  String _itemName(_Line l) => l.itemId == _otherItem
      ? l.otherName.text.trim()
      : widget.names.of('items', l.itemId, fallback: 'Item');

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => busy = true);
    final pickup = handover == 'Door to Door'
        ? (useSavedAddress && savedAddress != null
              ? savedAddress
              : address.text.trim())
        : null;
    final results = <Map<String, dynamic>>[];
    String? error;
    // The database keeps one item per donation record, so each line becomes
    // its own donation with its own QR reference.
    for (final l in lines) {
      final body = <String, dynamic>{
        'report_id': widget.report['id'],
        if (l.itemId == _otherItem) ...{
          'other_item_name': l.otherName.text.trim(),
          'other_item_unit': l.otherUnit.text.trim(),
        } else
          'item_id': int.parse(l.itemId!),
        'packaging': l.packaging == 'Other'
            ? l.otherPackaging.text.trim()
            : l.packaging,
        'quantity': int.parse(l.qty.text.trim()),
        'estimated_value': double.tryParse(l.value.text.trim()),
        'handover_method': handover,
        'pickup_address': pickup,
        if (!api.loggedIn)
          'guest_donor': {
            'full_name': guestName.text.trim(),
            'contact_number': guestPhone.text.trim(),
          },
      };
      final r = await api.post('/donations/', body: body);
      if (!r.ok) {
        error = r.status == 0 ? 'Cannot reach the server' : r.errorText;
        break;
      }
      final qr = await api.get('/donations/${r.json['donation_id']}/qr');
      results.add({
        ...Map<String, dynamic>.from(r.json as Map),
        'item_label': _itemName(l),
        'qr_image_base64': qr.ok ? qr.json['qr_image_base64'] : null,
      });
    }
    if (!mounted) return;
    setState(() => busy = false);
    final messenger = ScaffoldMessenger.of(context);
    if (error != null) {
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFFC62828),
          content: Text(
            results.isEmpty
                ? error
                : '${results.length} item(s) saved, then: $error',
          ),
        ),
      );
      if (results.isEmpty) return;
    }
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => DonationReceipt(
          donations: results,
          reportTitle:
              '${widget.report['disaster']} in ${widget.report['barangay']}',
        ),
      ),
    );
  }

  Widget _lineCard(int i) {
    final l = lines[i];
    final items = widget.names.rows('items');
    String unit = '';
    for (final it in items) {
      if ('${it['id']}' == l.itemId) unit = '${it['unit'] ?? ''}';
    }
    if (l.itemId == _otherItem) unit = l.otherUnit.text.trim();
    return Card(
      key: ObjectKey(l),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: l.itemId,
                    isExpanded: true,
                    decoration: InputDecoration(labelText: 'Item ${i + 1}'),
                    items: [
                      for (final it in items)
                        DropdownMenuItem(
                          value: '${it['id']}',
                          child: Text('${it['item_name'] ?? it['name']}'),
                        ),
                      const DropdownMenuItem(
                        value: _otherItem,
                        child: Text('Other…'),
                      ),
                    ],
                    onChanged: (v) => setState(() => l.itemId = v),
                    validator: (v) => v == null ? 'Choose an item' : null,
                  ),
                ),
                if (lines.length > 1)
                  IconButton(
                    tooltip: 'Remove this item',
                    onPressed: () => setState(() => lines.removeAt(i)),
                    icon: const Icon(Icons.close),
                  ),
              ],
            ),
            if (l.itemId == _otherItem) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextFormField(
                      controller: l.otherName,
                      decoration: const InputDecoration(
                        labelText: 'What item?',
                      ),
                      validator: _req,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      controller: l.otherUnit,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Unit',
                        hintText: 'pcs, boxes',
                      ),
                      validator: _req,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: l.qty,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Quantity',
                      suffixText: unit.isEmpty ? null : unit,
                    ),
                    validator: (v) => (int.tryParse(v?.trim() ?? '') ?? 0) > 0
                        ? null
                        : 'Above 0',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: l.packaging,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Packaging'),
                    items: [
                      for (final o in packagingOptions)
                        DropdownMenuItem(value: o, child: Text(o)),
                    ],
                    onChanged: (v) => setState(() => l.packaging = v!),
                  ),
                ),
              ],
            ),
            if (l.packaging == 'Other') ...[
              const SizedBox(height: 10),
              TextFormField(
                controller: l.otherPackaging,
                decoration: const InputDecoration(
                  labelText: 'Describe the packaging',
                ),
                validator: _req,
              ),
            ],
            const SizedBox(height: 10),
            TextFormField(
              controller: l.value,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Estimated value in PHP (optional)',
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.report;
    return Scaffold(
      appBar: AppBar(title: const Text('Physical Donation')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.flood_outlined, color: Brand.pink),
                title: Text('${r['disaster']} in Barangay ${r['barangay']}'),
                subtitle: Text('Needs: ${r['assistance_needed'] ?? '-'}'),
                trailing: Badge2.priority(r['priority_level'] as String?),
              ),
            ),
            SectionTitle(
              'What are you donating?',
              trailing: TextButton.icon(
                onPressed: () => setState(() => lines.add(_Line())),
                icon: const Icon(Icons.add),
                label: const Text('Add another item'),
              ),
            ),
            for (var i = 0; i < lines.length; i++) _lineCard(i),
            const SectionTitle('How will you hand it over?'),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'Drop Off',
                  label: Text('Drop Off'),
                  icon: Icon(Icons.store_mall_directory_outlined),
                ),
                ButtonSegment(
                  value: 'Door to Door',
                  label: Text('Door to Door'),
                  icon: Icon(Icons.local_shipping_outlined),
                ),
              ],
              selected: {handover},
              onSelectionChanged: (s) => setState(() => handover = s.first),
            ),
            const SizedBox(height: 12),
            if (handover == 'Drop Off')
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Brand.pinkSoft.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Storage details',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(Icons.place_outlined, size: 18),
                        SizedBox(width: 6),
                        Expanded(child: Text(storageAddress)),
                      ],
                    ),
                    SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.schedule, size: 18),
                        SizedBox(width: 6),
                        Expanded(child: Text(storageHours)),
                      ],
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Bring the goods and show your QR code. CSWS will count '
                      'what arrives and record the actual quantity.',
                      style: TextStyle(fontSize: 12, color: Brand.muted),
                    ),
                  ],
                ),
              )
            else ...[
              if (savedAddress != null) ...[
                RadioGroup<bool>(
                  groupValue: useSavedAddress,
                  onChanged: (v) => setState(() => useSavedAddress = v!),
                  child: Column(
                    children: [
                      RadioListTile<bool>(
                        value: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Use my registered address'),
                        subtitle: Text(savedAddress!),
                      ),
                      const RadioListTile<bool>(
                        value: false,
                        contentPadding: EdgeInsets.zero,
                        title: Text('Use another address'),
                      ),
                    ],
                  ),
                ),
              ],
              if (savedAddress == null || !useSavedAddress)
                TextFormField(
                  controller: address,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Pickup address',
                    hintText: 'House no., street, barangay',
                  ),
                  validator: _req,
                ),
            ],
            if (!api.loggedIn) ...[
              const SectionTitle('Your details (guest)'),
              TextFormField(
                controller: guestName,
                decoration: const InputDecoration(labelText: 'Full name'),
                validator: _req,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: guestPhone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Contact number'),
                validator: _req,
              ),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: busy ? null : _submit,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
              ),
              icon: const Icon(Icons.qr_code_2),
              label: Text(
                lines.length > 1
                    ? 'Submit ${lines.length} items & get QR codes'
                    : 'Submit & get QR code',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// QR receipt: one QR code per donated item.
class DonationReceipt extends StatelessWidget {
  final List<Map<String, dynamic>> donations;
  final String reportTitle;
  const DonationReceipt({
    super.key,
    required this.donations,
    required this.reportTitle,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Donation recorded')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Icon(Icons.check_circle, color: Color(0xFF2E7D32), size: 56),
          const SizedBox(height: 8),
          const Text(
            'Thank you!',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            'For $reportTitle. Show '
            '${donations.length > 1 ? 'these QR codes' : 'this QR code'} '
            'to the CSWS Main Office.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Brand.muted),
          ),
          const SizedBox(height: 16),
          for (final d in donations)
            Card(
              margin: const EdgeInsets.only(bottom: 14),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text(
                      '${d['quantity']} × ${d['item_label']} (${d['packaging']})',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (d['qr_image_base64'] != null)
                      Image.memory(
                        base64Decode(d['qr_image_base64'] as String),
                        width: 200,
                        height: 200,
                      ),
                    SelectableText(
                      '${d['qr_reference']}',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        Badge2('${d['handover_method']}', Colors.blueGrey),
                        Badge2.status('${d['status']}'),
                      ],
                    ),
                    if (d['pickup_address'] != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Pickup: ${d['pickup_address']}',
                        style: const TextStyle(color: Brand.muted),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
            ),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}

const _donationSteps = ['Pending', 'Received', 'Confirmed'];

/// Pending -> Received (CSWS) -> Confirmed (CMO), as small labeled dots.
class _DonationSteps extends StatelessWidget {
  final String status;
  const _DonationSteps(this.status);

  @override
  Widget build(BuildContext context) {
    final at = _donationSteps.indexOf(status);
    const labels = ['Submitted', 'Received by CSWS', 'Confirmed by City'];
    return Row(
      children: [
        for (var i = 0; i < 3; i++) ...[
          Icon(
            i <= at ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 16,
            color: i <= at ? Brand.pink : Colors.black26,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              labels[i],
              style: TextStyle(
                fontSize: 11,
                color: i <= at ? Brand.ink : Brand.muted,
              ),
            ),
          ),
          if (i < 2) const SizedBox(width: 8),
        ],
      ],
    );
  }
}

/// UC-D3 / UC-D4 (donor) and UC-R3 / UC-R4 (relief organization):
/// own donation history, status, supported reports and their fulfillment.
class DonorDashboard extends StatelessWidget {
  const DonorDashboard({super.key});

  Future<void> _showQr(BuildContext context, Map d) async {
    final r = await api.get('/donations/${d['donation_id']}/qr');
    if (!context.mounted || !r.ok) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${d['qr_reference']}'),
        content: Image.memory(
          base64Decode(r.json['qr_image_base64'] as String),
          width: 220,
          height: 220,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [() => api.get('/donations/mine'), api.lookupsResult],
      builder: (context, data) {
        final m = data[0] as Map;
        final profile = m['profile'] as Map, sum = m['summary'] as Map;
        final donations = (m['donations'] as List).cast<Map>();
        final supported = (m['supported_reports'] as List).cast<Map>();
        final active = Names(Map<String, dynamic>.from(data[1] as Map))
            .rows('validated_reports');
        final isOrg = profile['organization'] != null;
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            PageHeader(
              isOrg ? 'Relief Organization Dashboard' : 'Donor Dashboard',
              subtitle: isOrg
                  ? '${profile['organization']} • ${roleLine()}'
                  : '${profile['name']} • ${roleLine()}',
            ),
            if (isOrg)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    const Text(
                      'Account status: ',
                      style: TextStyle(color: Brand.muted),
                    ),
                    Badge2.status(
                      profile['account_status'] == 'Approved'
                          ? 'Validated'
                          : '${profile['account_status']}',
                    ),
                  ],
                ),
              ),
            StatGrid([
              StatTile(
                'Total donations',
                '${sum['total_donations']}',
                Icons.volunteer_activism_outlined,
              ),
              StatTile(
                'Waiting for drop-off / pickup',
                '${sum['pending']}',
                Icons.hourglass_top,
                color: const Color(0xFFEF6C00),
              ),
              StatTile(
                'Received by CSWS',
                '${sum['received']}',
                Icons.inventory_2_outlined,
                color: const Color(0xFF1565C0),
              ),
              StatTile(
                'Confirmed by the City',
                '${sum['confirmed']}',
                Icons.verified_outlined,
                color: const Color(0xFF2E7D32),
              ),
              StatTile(
                'Reports supported',
                '${sum['supported_reports']}',
                Icons.flag_outlined,
              ),
              StatTile(
                'Total quantity given',
                '${sum['total_quantity']}',
                Icons.inventory_outlined,
              ),
            ]),
            const SectionTitle('Donation history'),
            if (donations.isEmpty)
              const EmptyState(
                'No donations yet. Open Validated Reports to donate.',
              ),
            for (final d in donations)
              Card(
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
                              '${d['quantity']} ${d['unit']} ${d['item_name']}',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Badge2.status('${d['status']}'),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${d['qr_reference']} · ${d['packaging']} · '
                        '${d['handover_method']} · ${niceDate(d['created_at'])}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Brand.muted,
                        ),
                      ),
                      if (d['report'] != null)
                        Text(
                          'For: ${d['report']['label']}',
                          style: const TextStyle(fontSize: 13),
                        ),
                      const SizedBox(height: 10),
                      _DonationSteps('${d['status']}'),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: () => _showQr(context, d),
                          icon: const Icon(Icons.qr_code_2),
                          label: const Text('Show QR'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const SectionTitle('Supported reports'),
            if (supported.isEmpty)
              const EmptyState('You have not supported a report yet.'),
            for (final r in supported)
              Card(
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
                              '${r['label']}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Badge2.priority(r['priority_level'] as String?),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Progress(
                        delivered: r['total_items_delivered'] as num? ?? 0,
                        needed: r['total_items_needed'] as num? ?? 0,
                        percent: r['fulfillment_percentage'] as num?,
                      ),
                    ],
                  ),
                ),
              ),
            const SectionTitle('Active reports and priority'),
            if (active.isEmpty) const EmptyState('No active reports.'),
            for (final r in active.take(5))
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  dense: true,
                  title: Text('${r['disaster']} in ${r['barangay']}'),
                  subtitle: Text(
                    'Fulfilled ${(r['fulfillment_percentage'] as num? ?? 0).toStringAsFixed(0)}%',
                  ),
                  trailing: Badge2.priority(r['priority_level'] as String?),
                ),
              ),
          ],
        );
      },
    );
  }
}
