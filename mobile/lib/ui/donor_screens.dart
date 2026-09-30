import 'dart:convert';

import 'package:flutter/material.dart';

import 'widgets.dart';

/// UC-D2 / UC-R2 step 1-3: browse validated reports and pick one to support.
class ReportsFeed extends StatelessWidget {
  const ReportsFeed({super.key});

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [() => api.get('/lookups')],
      builder: (context, data) {
        final names = Names(Map<String, dynamic>.from(data[0] as Map));
        final reports = names.rows('validated_reports');
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Reports needing help',
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            const Text('Validated by the City. Pick one to donate goods to.'),
            const SizedBox(height: 12),
            if (reports.isEmpty)
              const EmptyState('No validated reports right now.'),
            for (final r in reports)
              Card(
                margin: const EdgeInsets.only(bottom: 12),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => DonateScreen(report: r, names: names),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${r['disaster']} in ${r['barangay']}',
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Badge2.priority(r['priority_level'] as String?),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          [
                            if (r['affected_families'] != null)
                              '${r['affected_families']} families affected',
                            if (r['assistance_needed'] != null)
                              'Needs: ${r['assistance_needed']}',
                          ].join('  ·  '),
                        ),
                        if (r['description'] != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            '${r['description']}',
                            style: Theme.of(context).textTheme.bodySmall,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                        const SizedBox(height: 10),
                        Progress(
                          delivered: r['total_items_delivered'] as num? ?? 0,
                          needed: r['total_items_needed'] as num? ?? 0,
                          percent: r['fulfillment_percentage'] as num?,
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton.tonalIcon(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    DonateScreen(report: r, names: names),
                              ),
                            ),
                            icon: const Icon(Icons.volunteer_activism),
                            label: const Text('Donate'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
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
