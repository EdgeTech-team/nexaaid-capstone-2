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

/// UC-D2 step 5-6: physical donation form, then QR receipt.
class DonateScreen extends StatefulWidget {
  final Map<String, dynamic> report;
  final Names names;
  const DonateScreen({super.key, required this.report, required this.names});

  @override
  State<DonateScreen> createState() => _DonateScreenState();
}

class _DonateScreenState extends State<DonateScreen> {
  final _form = GlobalKey<FormState>();
  String? itemId;
  String handover = 'Drop Off';
  final packaging = TextEditingController(text: 'Box');
  final qty = TextEditingController();
  final value = TextEditingController();
  final address = TextEditingController();
  final guestName = TextEditingController();
  final guestPhone = TextEditingController();
  bool busy = false;

  @override
  void initState() {
    super.initState();
    final items = widget.names.rows('items');
    if (items.isNotEmpty) itemId = '${items.first['id']}';
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => busy = true);
    final body = <String, dynamic>{
      'report_id': widget.report['id'],
      'item_id': int.parse(itemId!),
      'packaging': packaging.text.trim(),
      'quantity': int.parse(qty.text.trim()),
      'estimated_value': double.tryParse(value.text.trim()),
      'handover_method': handover,
      'pickup_address': handover == 'Door to Door' ? address.text.trim() : null,
      if (!api.loggedIn)
        'guest_donor': {
          'full_name': guestName.text.trim(),
          'contact_number': guestPhone.text.trim(),
        },
    };
    final r = await act(
      context,
      () => api.post('/donations/', body: body),
      success: 'Donation recorded. Show the QR code when handing over.',
    );
    if (!mounted) return;
    setState(() => busy = false);
    if (!r.ok) return;
    final qr = await api.get('/donations/${r.json['donation_id']}/qr');
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => DonationReceipt(
          donation: Map<String, dynamic>.from(r.json as Map),
          qrBase64: qr.ok ? qr.json['qr_image_base64'] as String? : null,
          itemName: widget.names.of('items', itemId),
          reportTitle:
              '${widget.report['disaster']} in ${widget.report['barangay']}',
        ),
      ),
    );
  }

  String? _req(String? v) => (v ?? '').trim().isEmpty ? 'Required' : null;

  @override
  Widget build(BuildContext context) {
    final r = widget.report;
    return Scaffold(
      appBar: AppBar(title: const Text('Donate goods')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.flood_outlined),
                title: Text('${r['disaster']} in ${r['barangay']}'),
                subtitle: Text('Needs: ${r['assistance_needed'] ?? '-'}'),
                trailing: Badge2.priority(r['priority_level'] as String?),
              ),
            ),
            const SectionTitle('What are you donating?'),
            LookupDropdown(
              list: 'items',
              label: 'Item',
              value: itemId,
              names: widget.names,
              onChanged: (v) => setState(() => itemId = v),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: qty,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Quantity'),
                    validator: (v) => (int.tryParse(v?.trim() ?? '') ?? 0) > 0
                        ? null
                        : 'Enter a number above 0',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: packaging,
                    decoration: const InputDecoration(
                      labelText: 'Packaging',
                      hintText: 'Box, sack, pack',
                    ),
                    validator: _req,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: value,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Estimated value in PHP (optional)',
              ),
            ),
            const SectionTitle('How will you hand it over?'),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'Drop Off',
                  label: Text('Drop off'),
                  icon: Icon(Icons.store_mall_directory_outlined),
                ),
                ButtonSegment(
                  value: 'Door to Door',
                  label: Text('Pick up'),
                  icon: Icon(Icons.local_shipping_outlined),
                ),
              ],
              selected: {handover},
              onSelectionChanged: (s) => setState(() => handover = s.first),
            ),
            const SizedBox(height: 10),
            if (handover == 'Drop Off')
              const Text(
                'Bring the goods to the CSWS Main Office and show your QR code.',
              )
            else
              TextFormField(
                controller: address,
                decoration: const InputDecoration(labelText: 'Pickup address'),
                validator: _req,
              ),
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
              label: const Text('Submit & get QR code'),
            ),
          ],
        ),
      ),
    );
  }
}

class DonationReceipt extends StatelessWidget {
  final Map<String, dynamic> donation;
  final String? qrBase64;
  final String itemName;
  final String reportTitle;
  const DonationReceipt({
    super.key,
    required this.donation,
    required this.qrBase64,
    required this.itemName,
    required this.reportTitle,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Donation recorded')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Icon(Icons.check_circle, color: Color(0xFF2E7D32), size: 56),
          const SizedBox(height: 8),
          Text(
            'Thank you!',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            'Show this QR code to the CSWS Main Office.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          if (qrBase64 != null)
            Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                color: Colors.white,
                child: Image.memory(
                  base64Decode(qrBase64!),
                  width: 220,
                  height: 220,
                ),
              ),
            ),
          const SizedBox(height: 8),
          SelectableText(
            '${donation['qr_reference']}',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Column(
              children: [
                ListTile(
                  dense: true,
                  title: const Text('Donation'),
                  trailing: Text(
                    '${donation['quantity']} × $itemName (${donation['packaging']})',
                  ),
                ),
                ListTile(
                  dense: true,
                  title: const Text('For'),
                  trailing: Text(reportTitle),
                ),
                ListTile(
                  dense: true,
                  title: const Text('Handover'),
                  trailing: Text('${donation['handover_method']}'),
                ),
                ListTile(
                  dense: true,
                  title: const Text('Status'),
                  trailing: Badge2.status('${donation['status']}'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}
