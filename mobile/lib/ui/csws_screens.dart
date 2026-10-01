import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'records_screens.dart' show DonationRecordsScreen;
import 'widgets.dart';

/// Camera QR scanner. Returns the scanned text (e.g. DON-1A2B3C...).
class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  bool done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: const Text('Scan donation QR')),
      body: Stack(
        children: [
          MobileScanner(
            onDetect: (capture) {
              if (done) return;
              final code = capture.barcodes
                  .map((b) => b.rawValue)
                  .whereType<String>()
                  .firstOrNull;
              if (code == null) return;
              done = true;
              Navigator.of(context).pop(code);
            },
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Camera not available (${error.errorCode.name}).\n'
                  'Go back and type the reference instead.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
          const Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Point the camera at the donor\'s QR code',
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens the donation found by QR reference and lets CSWS receive it.
Future<void> openDonationByQr(BuildContext context, String reference) async {
  final ref = reference.trim();
  if (ref.isEmpty) return;
  final r = await api.get('/donations/by-qr/${Uri.encodeComponent(ref)}');
  if (!context.mounted) return;
  if (!r.ok) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFFC62828),
        content: Text(r.status == 0 ? 'Cannot reach the server' : r.errorText),
      ),
    );
    return;
  }
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => DonationSheet(Map<String, dynamic>.from(r.json as Map)),
  );
}

/// Donation details as declared by the donor, plus the Receive action.
class DonationSheet extends StatelessWidget {
  final Map<String, dynamic> d;
  const DonationSheet(this.d, {super.key});

  Future<void> _receive(BuildContext context) async {
    final v = await formDialog(
      context,
      title: 'Receive ${d['qr_reference']}',
      message:
          'Declared: ${d['quantity']} ${d['unit']} ${d['item_name']}. '
          'Record what was actually accepted.',
      fields: [
        DialogField(
          'qty',
          'Actual quantity received (${d['unit']})',
          number: true,
          initial: '${d['quantity']}',
        ),
        const DialogField('notes', 'Notes (optional)', required: false),
      ],
      confirm: 'Receive into inventory',
    );
    if (v == null || !context.mounted) return;
    final r = await act(
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
    if (r.ok && context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    Widget row(String k, dynamic v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(k, style: const TextStyle(color: Brand.muted)),
          ),
          Expanded(child: Text('${v ?? '-'}')),
        ],
      ),
    );
    final pending = d['status'] == 'Pending';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${d['qr_reference']}',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              Badge2.status('${d['status']}'),
            ],
          ),
          const SizedBox(height: 10),
          row('Item', '${d['item_name']}'),
          row('Declared quantity', '${d['quantity']} ${d['unit']}'),
          row('Packaging', d['packaging']),
          row(
            'Estimated value',
            d['estimated_value'] == null ? null : 'PHP ${d['estimated_value']}',
          ),
          row('Handover', d['handover_method']),
          if (d['pickup_address'] != null)
            row('Pickup at', d['pickup_address']),
          row('Donor', d['donor']),
          row('For report', d['report_label']),
          if (d['actual_quantity_received'] != null)
            row('Received', '${d['actual_quantity_received']} ${d['unit']}'),
          const SizedBox(height: 16),
          if (pending)
            FilledButton.icon(
              onPressed: () => _receive(context),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              icon: const Icon(Icons.move_to_inbox),
              label: const Text('Receive goods'),
            )
          else
            Text(
              'Already ${d['status']}.',
              style: const TextStyle(color: Brand.muted),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// UC-CM1 Handle physical donations
// ---------------------------------------------------------------------------
class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({super.key});

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  final searchC = TextEditingController();
  String search = '';
  String view = 'pending';

  Future<void> _scan() async {
    final code = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const ScannerPage()));
    if (code != null && mounted) await openDonationByQr(context, code);
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
        final q = search.toLowerCase();
        final pending = (data[0] as List)
            .cast<Map>()
            .where((d) => '${d['qr_reference']}'.toLowerCase().contains(q))
            .toList();
        final inventory = (data[1] as List).cast<Map>();
        // Inventory is linked to specific reports (Inventory module rules).
        final byReport = <String, List<Map>>{};
        for (final i in inventory) {
          byReport
              .putIfAbsent(
                '${i['report_label'] ?? 'Report #${i['report_id']}'}',
                () => [],
              )
              .add(i);
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const PageHeader(
              'Handle Physical Donations',
              subtitle:
                  'Scan the donor\'s QR code (or search the reference), check '
                  'the goods, and record the actual quantity received.',
            ),
            FilledButton.icon(
              onPressed: _scan,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan QR code'),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: const Text('Donation records')),
                      body: const DonationRecordsScreen(header: false),
                    ),
                  ),
                ),
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('All donation records'),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: searchC,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      labelText: 'Or type the QR reference',
                      hintText: 'DON-...',
                    ),
                    onChanged: (v) => setState(() => search = v.trim()),
                    onSubmitted: (v) => openDonationByQr(context, v),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => openDonationByQr(context, searchC.text),
                  child: const Text('Find'),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(
                  value: 'pending',
                  label: Text('Pending (${pending.length})'),
                ),
                ButtonSegment(
                  value: 'inventory',
                  label: Text('Inventory (${byReport.length})'),
                ),
              ],
              selected: {view},
              onSelectionChanged: (s) => setState(() => view = s.first),
            ),
            const SizedBox(height: 12),
            if (view == 'pending') ...[
              if (pending.isEmpty)
                const EmptyState('Nothing waiting to be received.'),
              for (final d in pending)
                Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    leading: const CircleAvatar(
                      child: Icon(Icons.inventory_2_outlined),
                    ),
                    title: Text(
                      '${d['quantity']} × '
                      '${names.of('items', d['item_id'], fallback: 'item')}',
                    ),
                    subtitle: Text(
                      '${d['qr_reference']} · ${d['packaging']} · '
                      '${d['handover_method']}'
                      '${d['pickup_address'] != null ? '\nPickup: ${d['pickup_address']}' : ''}',
                    ),
                    isThreeLine: d['pickup_address'] != null,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () =>
                        openDonationByQr(context, '${d['qr_reference']}'),
                  ),
                ),
            ] else ...[
              if (byReport.isEmpty) const EmptyState('Inventory is empty.'),
              for (final e in byReport.entries)
                Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          e.key,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const Divider(),
                        for (final i in e.value)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.warehouse_outlined,
                                  size: 18,
                                  color: Brand.muted,
                                ),
                                const SizedBox(width: 8),
                                Expanded(child: Text('${i['item_name']}')),
                                Text(
                                  '${i['quantity']} ${i['unit'] ?? ''}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// UC-CM3 / manuscript 7.1 CSWS Main Office dashboard
// ---------------------------------------------------------------------------
class CswsMainDashboard extends StatelessWidget {
  const CswsMainDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [() => api.get('/dashboard/csws-main')],
      builder: (context, data) {
        final m = data[0] as Map;
        final inv = (m['inventory_summary'] as List).cast<Map>();
        final entries = (m['donation_entries'] as List).cast<Map>();
        final logs = (m['recent_activity'] as List).cast<Map>();
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            PageHeader('CSWS Main Office Dashboard', subtitle: roleLine()),
            StatGrid([
              StatTile(
                'Pending donations',
                '${m['pending_donations']}',
                Icons.hourglass_top,
                color: const Color(0xFFEF6C00),
              ),
              StatTile(
                'Entries received',
                '${m['entries_received']}',
                Icons.move_to_inbox_outlined,
              ),
              StatTile(
                'Total quantity received',
                '${m['total_quantity_received']}',
                Icons.inventory_2_outlined,
              ),
              StatTile(
                'Deliveries made',
                '${m['deliveries_made']}',
                Icons.local_shipping_outlined,
              ),
              StatTile(
                'Total quantity distributed',
                '${m['total_quantity_distributed']}',
                Icons.outbox_outlined,
                color: const Color(0xFF2E7D32),
              ),
            ]),
            const SectionTitle('Inventory summary'),
            if (inv.isEmpty) const EmptyState('Inventory is empty.'),
            Card(
              child: Column(
                children: [
                  for (final i in inv)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.warehouse_outlined),
                      title: Text('${i['item']}'),
                      trailing: Text(
                        '${i['quantity']} ${i['unit']}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                ],
              ),
            ),
            const SectionTitle('Donation entries'),
            if (entries.isEmpty) const EmptyState('No donations yet.'),
            for (final d in entries)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  title: Text(
                    '${d['declared_quantity']} ${d['unit']} ${d['item_name']} · ${d['packaging']}',
                  ),
                  subtitle: Text(
                    '${d['qr_reference']} · ${d['handover_method']}'
                    '${d['estimated_value'] != null ? ' · PHP ${d['estimated_value']}' : ''}'
                    '\n${d['report_label'] ?? ''}',
                  ),
                  isThreeLine: true,
                  trailing: Badge2.status('${d['status']}'),
                ),
              ),
            const SectionTitle('Recent activity'),
            ActivityList(logs),
          ],
        );
      },
    );
  }
}

/// Activity log rows (audit_logs).
class ActivityList extends StatelessWidget {
  final List<Map> logs;
  const ActivityList(this.logs, {super.key});

  @override
  Widget build(BuildContext context) {
    if (logs.isEmpty) return const EmptyState('No activity yet.');
    return Card(
      child: Column(
        children: [
          for (final l in logs)
            ListTile(
              dense: true,
              leading: const Icon(Icons.history, size: 20),
              title: Text(
                '${l['action']}'
                '${l['entity_id'] != null ? ' #${l['entity_id']}' : ''}',
              ),
              subtitle: Text(
                '${l['user'] ?? l['by']} · ${niceDate(l['timestamp'] ?? l['at'])}',
              ),
            ),
        ],
      ),
    );
  }
}
