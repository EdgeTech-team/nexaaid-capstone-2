import 'package:flutter/material.dart';

import 'widgets.dart';

const _deliverySteps = ['Preparing', 'In Transit', 'Delivered', 'Confirmed'];

/// Preparing -> In Transit -> Delivered -> Confirmed, as a dot stepper.
class DeliveryStepper extends StatelessWidget {
  final String status;
  const DeliveryStepper(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    final at = _deliverySteps.indexOf(status);
    final on = Theme.of(context).colorScheme.primary;
    return Row(
      children: [
        for (var i = 0; i < _deliverySteps.length; i++) ...[
          Column(
            children: [
              CircleAvatar(
                radius: 11,
                backgroundColor: i <= at ? on : Colors.black12,
                child: i < at || (i == at && i == _deliverySteps.length - 1)
                    ? const Icon(Icons.check, size: 14, color: Colors.white)
                    : Text(
                        '${i + 1}',
                        style: TextStyle(
                          fontSize: 11,
                          color: i <= at ? Colors.white : Colors.black54,
                        ),
                      ),
              ),
              const SizedBox(height: 3),
              Text(
                _deliverySteps[i],
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: i == at ? FontWeight.w700 : FontWeight.normal,
                ),
              ),
            ],
          ),
          if (i < _deliverySteps.length - 1)
            Expanded(
              child: Container(
                height: 2,
                margin: const EdgeInsets.only(bottom: 14),
                color: i < at ? on : Colors.black12,
              ),
            ),
        ],
      ],
    );
  }
}

String _donationTitle(Map d, Names n) =>
    '${d['quantity']} × ${n.of('items', d['item_id'], fallback: 'item')}';

// ---------------------------------------------------------------------------
// UC-CM1 Handle physical donations (CSWS Main Office)
// ---------------------------------------------------------------------------
class DonationsInScreen extends StatefulWidget {
  const DonationsInScreen({super.key});

  @override
  State<DonationsInScreen> createState() => _DonationsInScreenState();
}

class _DonationsInScreenState extends State<DonationsInScreen> {
  String search = '';

  Future<void> _receive(Map d, Names n) async {
    final v = await formDialog(
      context,
      title: 'Receive ${d['qr_reference']}',
      message:
          'Declared: ${_donationTitle(d, n)} (${d['packaging']}).\n'
          'Count what actually arrived.',
      fields: [
        DialogField(
          'qty',
          'Actual quantity received',
          number: true,
          initial: '${d['quantity']}',
        ),
        const DialogField('notes', 'Notes (optional)', required: false),
      ],
      confirm: 'Receive into inventory',
    );
    if (v == null || !mounted) return;
    await act(
      context,
      () => api.post(
        '/donations/receive',
        body: {
          'donation_id': d['donation_id'],
          'actual_quantity': int.parse(v['qty']!),
          'notes': v['notes']!.isEmpty ? null : v['notes'],
        },
      ),
      success: '${d['qr_reference']} received and added to inventory',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [
        () => api.get('/donations/pending'),
        () => api.get('/donations/inventory'),
        api.lookupsResult,
      ],
      builder: (context, data) {
        final names = Names(Map<String, dynamic>.from(data[2] as Map));
        final pending = (data[0] as List)
            .cast<Map>()
            .where(
              (d) => '${d['qr_reference']}'.toLowerCase().contains(
                search.toLowerCase(),
              ),
            )
            .toList();
        final inventory = (data[1] as List).cast<Map>();
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            PageHeader('Physical Donations', subtitle: roleLine()),
            TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.qr_code_scanner),
                labelText: 'Find by QR reference',
                hintText: 'DON-...',
              ),
              onChanged: (v) => setState(() => search = v.trim()),
            ),
            SectionTitle('Pending donations (${pending.length})'),
            if (pending.isEmpty)
              const EmptyState('Nothing waiting to be received.'),
            for (final d in pending)
              Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: ListTile(
                  leading: const CircleAvatar(
                    child: Icon(Icons.inventory_2_outlined),
                  ),
                  title: Text(_donationTitle(d, names)),
                  subtitle: Text(
                    '${d['qr_reference']} · ${d['handover_method']}\n'
                    'For ${names.of('reports', d['report_id'], fallback: 'report #${d['report_id']}')}',
                  ),
                  isThreeLine: true,
                  trailing: FilledButton(
                    onPressed: () => _receive(d, names),
                    child: const Text('Receive'),
                  ),
                ),
              ),
            SectionTitle('Inventory (${inventory.length})'),
            if (inventory.isEmpty) const EmptyState('Inventory is empty.'),
            for (final i in inventory)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.warehouse_outlined),
                  title: Text('${i['item_name']}'),
                  subtitle: Text(
                    names.of(
                      'reports',
                      i['report_id'],
                      fallback: 'Report #${i['report_id']}',
                    ),
                  ),
                  trailing: Text(
                    '${i['quantity']}',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
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

// ---------------------------------------------------------------------------
// UC-CM2 Prepare release and delivery tracking (CSWS Main Office)
// ---------------------------------------------------------------------------
class DeliveriesScreen extends StatelessWidget {
  final bool barangay; // UC-B1: receiving side only
  const DeliveriesScreen({super.key, this.barangay = false});

  Future<void> _requestTransport(BuildContext context, Map d) async {
    final v = await formDialog(
      context,
      title: 'Request DRRMO transport',
      message: 'For delivery #${d['delivery_id']}.',
      fields: const [
        DialogField(
          'notes',
          'What is needed',
          hint: 'e.g. 1 truck, 2 volunteers',
          required: false,
        ),
      ],
      confirm: 'Send request',
    );
    if (v == null || !context.mounted) return;
    await act(
      context,
      () => api.post(
        '/logistics/requests',
        body: {
          'delivery_id': d['delivery_id'],
          'notes': v['notes']!.isEmpty ? null : v['notes'],
        },
      ),
      success: 'Logistics request sent to DRRMO',
    );
  }

  Future<void> _confirmReceipt(BuildContext context, Map d) async {
    final v = await formDialog(
      context,
      title: 'Confirm receipt',
      message:
          'Confirm that delivery #${d['delivery_id']} arrived. This updates '
          'the report\'s fulfillment progress.',
      fields: const [
        DialogField(
          'remarks',
          'Remarks (optional)',
          required: false,
          multiline: true,
        ),
      ],
      confirm: 'Confirm receipt',
    );
    if (v == null || !context.mounted) return;
    await act(
      context,
      () => api.post(
        '/deliveries/${d['delivery_id']}/confirm-receipt',
        body: {'remarks': v['remarks']!.isEmpty ? null : v['remarks']},
      ),
      success: 'Receipt confirmed. Fulfillment updated.',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: barangay
          ? null
          : FloatingActionButton.extended(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const NewDeliveryScreen()),
              ),
              icon: const Icon(Icons.add),
              label: const Text('Prepare delivery'),
            ),
      body: Loader(
        load: [() => api.get('/deliveries/'), api.lookupsResult],
        builder: (context, data) {
          final names = Names(Map<String, dynamic>.from(data[1] as Map));
          final rows = (data[0] as List).cast<Map>();
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            children: [
              PageHeader(
                barangay ? 'Incoming Aid' : 'Release & Delivery Tracking',
                subtitle: roleLine(),
              ),
              if (rows.isEmpty)
                EmptyState(
                  barangay
                      ? 'No deliveries to your barangay yet.'
                      : 'No deliveries yet. Tap "Prepare delivery".',
                ),
              for (final d in rows) _card(context, d, names),
            ],
          );
        },
      ),
    );
  }

  Widget _card(BuildContext context, Map d, Names names) {
    final status = '${d['status']}';
    final i = _deliverySteps.indexOf(status);
    final next = i >= 0 && i < 2 ? _deliverySteps[i + 1] : null;
    final items = (d['items'] as List? ?? const [])
        .map(
          (it) =>
              '${it['quantity']} × ${names.of('items', it['item_id'], fallback: 'item')}',
        )
        .join(', ');
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
                    'Delivery #${d['delivery_id']} to '
                    '${names.of('barangays', d['destination_barangay_id'])}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Badge2.status(status),
              ],
            ),
            const SizedBox(height: 4),
            Text(items.isEmpty ? 'No items' : items),
            Text(
              '${names.of('reports', d['report_id'], fallback: 'Report #${d['report_id']}')}'
              ' · ${niceDate(d['delivery_date'])}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            DeliveryStepper(status),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 6,
              children: [
                if (!barangay &&
                    (status == 'Preparing' || status == 'In Transit'))
                  OutlinedButton.icon(
                    onPressed: () => _requestTransport(context, d),
                    icon: const Icon(Icons.fire_truck_outlined),
                    label: const Text('Request transport'),
                  ),
                if (!barangay && next != null)
                  FilledButton.icon(
                    onPressed: () => act(
                      context,
                      () => api.post('/deliveries/${d['delivery_id']}/advance'),
                      success: 'Delivery #${d['delivery_id']} is now $next',
                    ),
                    icon: const Icon(Icons.arrow_forward),
                    label: Text('Mark $next'),
                  ),
                if (barangay && status == 'Delivered')
                  FilledButton.icon(
                    onPressed: () => _confirmReceipt(context, d),
                    icon: const Icon(Icons.task_alt),
                    label: const Text('Confirm receipt'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class NewDeliveryScreen extends StatefulWidget {
  const NewDeliveryScreen({super.key});

  @override
  State<NewDeliveryScreen> createState() => _NewDeliveryScreenState();
}

class _NewDeliveryScreenState extends State<NewDeliveryScreen> {
  final _form = GlobalKey<FormState>();
  String? reportId, brgyId, itemId;
  final qty = TextEditingController();
  String? date;
  bool busy = false;

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    if (date == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Pick a delivery date')));
      return;
    }
    setState(() => busy = true);
    final r = await act(
      context,
      () => api.post(
        '/deliveries/',
        body: {
          'report_id': int.parse(reportId!),
          'destination_barangay_id': int.parse(brgyId!),
          'delivery_date': date,
          'items': [
            {'item_id': int.parse(itemId!), 'quantity': int.parse(qty.text)},
          ],
        },
      ),
      success: 'Delivery prepared',
    );
    if (!mounted) return;
    setState(() => busy = false);
    if (r.ok) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Prepare delivery')),
      body: FutureBuilder<Map<String, dynamic>>(
        future: api.lookups(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final names = Names(snap.data!);
          return Form(
            key: _form,
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                LookupDropdown(
                  list: 'validated_reports',
                  label: 'For which validated report?',
                  value: reportId,
                  names: names,
                  onChanged: (v) => setState(() => reportId = v),
                ),
                const SizedBox(height: 12),
                LookupDropdown(
                  list: 'barangays',
                  label: 'Destination barangay',
                  value: brgyId,
                  names: names,
                  onChanged: (v) => setState(() => brgyId = v),
                ),
                const SizedBox(height: 12),
                LookupDropdown(
                  list: 'items',
                  label: 'Item from inventory',
                  value: itemId,
                  names: names,
                  onChanged: (v) => setState(() => itemId = v),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: qty,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Quantity'),
                  validator: (v) => (int.tryParse(v?.trim() ?? '') ?? 0) > 0
                      ? null
                      : 'Enter a number above 0',
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () async {
                    final d = await pickDateTime(context);
                    if (d != null) setState(() => date = d);
                  },
                  icon: const Icon(Icons.event),
                  label: Text(
                    date == null ? 'Pick delivery date' : niceDate(date),
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: busy ? null : _submit,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                  ),
                  icon: const Icon(Icons.inventory),
                  label: const Text('Prepare delivery'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// UC-C1 / UC-C2 City donation confirmation (CMO Representative)
// ---------------------------------------------------------------------------
class CmoScreen extends StatelessWidget {
  const CmoScreen({super.key});

  Future<void> _decide(BuildContext context, Map d, String decision) async {
    String? notes;
    if (decision != 'Confirmed') {
      final v = await formDialog(
        context,
        title: decision == 'On Hold' ? 'Put on hold' : 'Keep for review',
        fields: const [DialogField('notes', 'Reason', multiline: true)],
      );
      if (v == null) return;
      notes = v['notes'];
    }
    if (!context.mounted) return;
    await act(
      context,
      () => api.post(
        '/cmo/donations/${d['donation_id']}/confirm',
        body: {'status': decision, 'notes': notes},
      ),
      success: decision == 'Confirmed'
          ? '${d['qr_reference']} officially confirmed'
          : '${d['qr_reference']} marked $decision',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [
        () => api.get('/cmo/dashboard'),
        () => api.get('/cmo/donations/pending'),
        api.lookupsResult,
      ],
      builder: (context, data) {
        final dash = data[0] as Map;
        final rows = (data[1] as List).cast<Map>();
        final names = Names(Map<String, dynamic>.from(data[2] as Map));
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            PageHeader('CMO Representative Dashboard', subtitle: roleLine()),
            StatGrid([
              StatTile(
                'Waiting for city confirmation',
                '${dash['pending_confirmation']}',
                Icons.hourglass_top,
                color: const Color(0xFFEF6C00),
              ),
              StatTile(
                'Officially confirmed',
                '${dash['confirmed']}',
                Icons.verified,
                color: const Color(0xFF2E7D32),
              ),
            ]),
            const SectionTitle('Donations received by CSWS'),
            if (rows.isEmpty) const EmptyState('No donations to confirm.'),
            for (final d in rows)
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
                              _donationTitle(d, names),
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Badge2.status('${d['status']}'),
                        ],
                      ),
                      Text('${d['qr_reference']} · ${d['packaging']}'),
                      Text(
                        names.of(
                          'reports',
                          d['report_id'],
                          fallback: 'Report #${d['report_id']}',
                        ),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 8,
                        children: [
                          TextButton(
                            onPressed: () =>
                                _decide(context, d, 'Pending Review'),
                            child: const Text('Review'),
                          ),
                          OutlinedButton(
                            onPressed: () => _decide(context, d, 'On Hold'),
                            child: const Text('Hold'),
                          ),
                          FilledButton.icon(
                            onPressed: () => _decide(context, d, 'Confirmed'),
                            icon: const Icon(Icons.verified),
                            label: const Text('Confirm'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// UC-DR1 / UC-DR2 Logistics support (DRRMO)
// ---------------------------------------------------------------------------
class DrrmoScreen extends StatelessWidget {
  const DrrmoScreen({super.key});

  Future<void> _accept(BuildContext context, Map r) async {
    final date = await pickDateTime(context);
    if (date == null || !context.mounted) return;
    await act(
      context,
      () => api.patch(
        '/drrmo/requests/${r['request_id']}/accept',
        body: {'scheduled_date': date},
      ),
      success: 'Scheduled for ${niceDate(date)}',
    );
  }

  Future<void> _decline(BuildContext context, Map r) async {
    final v = await formDialog(
      context,
      title: 'Decline request #${r['request_id']}',
      fields: const [DialogField('notes', 'Reason', multiline: true)],
      confirm: 'Decline',
    );
    if (v == null || !context.mounted) return;
    await act(
      context,
      () => api.patch(
        '/drrmo/requests/${r['request_id']}/decline',
        body: {'notes': v['notes']},
      ),
      success: 'Request declined',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [
        () => api.get('/drrmo/dashboard'),
        () => api.get('/drrmo/requests'),
        api.lookupsResult,
      ],
      builder: (context, data) {
        final dash = data[0] as Map;
        final rows = (data[1] as List).cast<Map>();
        final names = Names(Map<String, dynamic>.from(data[2] as Map));
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            PageHeader(
              'DRRMO Logistics Support Dashboard',
              subtitle: roleLine(),
            ),
            StatGrid([
              StatTile(
                'New requests',
                '${dash['pending_requests']}',
                Icons.mark_email_unread_outlined,
                color: const Color(0xFFEF6C00),
              ),
              StatTile(
                'Scheduled',
                '${dash['scheduled']}',
                Icons.event_available,
              ),
              StatTile(
                'Completed',
                '${dash['completed']}',
                Icons.done_all,
                color: const Color(0xFF2E7D32),
              ),
            ]),
            const SectionTitle('Requests from CSWS'),
            if (rows.isEmpty) const EmptyState('No new logistics requests.'),
            for (final r in rows)
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
                              'Request #${r['request_id']}',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Badge2.status('${r['status']}'),
                        ],
                      ),
                      Text(
                        names.of(
                          'open_deliveries',
                          r['delivery_id'],
                          fallback: 'Delivery #${r['delivery_id']}',
                        ),
                      ),
                      if (r['notes'] != null) Text('Needs: ${r['notes']}'),
                      Text(
                        'Requested ${niceDate(r['created_at'])}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          OutlinedButton(
                            onPressed: () => _decline(context, r),
                            child: const Text('Decline'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.icon(
                            onPressed: () => _accept(context, r),
                            icon: const Icon(Icons.event),
                            label: const Text('Accept & schedule'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
