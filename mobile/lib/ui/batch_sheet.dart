import 'package:flutter/material.dart';

import 'location_picker.dart' show formatPickupIso;
import 'pickup_actions.dart';
import 'widgets.dart';

/// UC-CM1 step 2: open a donation from its QR or typed reference. One QR
/// covers every item the donor submitted together, so this shows the whole
/// donation. Each item is still received and counted on its own
/// (UC-CM1 steps 3-8, alt 4a/4b) through POST /donations/receive.
///
/// Also accepts a per-item reference (DON-XXXX-2) and old single-item QRs.
Future<void> openDonationByQr(BuildContext context, String reference) async {
  final ref = reference.trim();
  if (ref.isEmpty) return;
  final r = await api.get('/donations/by-batch/${Uri.encodeComponent(ref)}');
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
    builder: (_) => BatchSheet(Map<String, dynamic>.from(r.json as Map)),
  );
}

/// Everything in one donation, as declared by the donor, with a Receive
/// action per item.
class BatchSheet extends StatefulWidget {
  final Map<String, dynamic> batch;
  const BatchSheet(this.batch, {super.key});

  @override
  State<BatchSheet> createState() => _BatchSheetState();
}

class _BatchSheetState extends State<BatchSheet> {
  late Map<String, dynamic> b = widget.batch;

  List<Map<String, dynamic>> get _items => (b['items'] as List? ?? const [])
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();

  Future<void> _reload() async {
    final r = await api.get(
      '/donations/by-batch/${Uri.encodeComponent('${b['batch_reference']}')}',
    );
    if (mounted && r.ok && r.json is Map) {
      setState(() => b = Map<String, dynamic>.from(r.json as Map));
    }
  }

  Future<void> _receive(Map<String, dynamic> line) async {
    final v = await formDialog(
      context,
      title: 'Receive ${line['item_name']}',
      message:
          'Declared: ${line['quantity']} ${line['unit']} '
          '(${line['packaging']}). Record what was actually accepted.',
      fields: [
        DialogField(
          'qty',
          'Actual quantity received (${line['unit']})',
          number: true,
          initial: '${line['quantity']}',
        ),
        const DialogField('notes', 'Notes (optional)', required: false),
      ],
      confirm: 'Receive into inventory',
    );
    if (v == null || !mounted) return;
    final r = await act(
      context,
      () => api.post(
        '/donations/receive',
        body: {
          'donation_id': line['donation_id'],
          'actual_quantity': int.parse(v['qty']!),
          'notes': v['notes']!.isEmpty ? null : v['notes'],
        },
      ),
      success: '${line['item_name']} received and added to inventory',
    );
    if (r.ok) await _reload();
  }

  Widget _row(String k, dynamic v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Text(k, style: const TextStyle(color: Brand.muted)),
        ),
        Expanded(child: Text('${v ?? '-'}')),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final lat = (b['pickup_lat'] as num?)?.toDouble();
    final lng = (b['pickup_lng'] as num?)?.toDouble();
    final pending = items.where((i) => i['status'] == 'Pending').length;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${b['batch_reference']}',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                Badge2.status('${b['status']}'),
              ],
            ),
            const SizedBox(height: 10),
            _row(
              'Donor',
              b['donor_type'] == null
                  ? b['donor']
                  : '${b['donor']} · ${b['donor_type']}',
            ),
            if ('${b['donor_contact'] ?? ''}'.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 110, bottom: 4),
                child: ContactButtons(
                  phone: '${b['donor_contact']}',
                  smsMessage:
                      'Hi, this is CSWS Mandaue about your NexaAid donation ${b['batch_reference']}.',
                ),
              ),
            if (b['donor_email'] != null) _row('Email', b['donor_email']),
            _row('For report', b['report_label']),
            _row('Handover', b['handover_method']),
            if (b['pickup_address'] != null)
              _row('Pickup at', b['pickup_address']),
            if (formatPickupIso(b['preferred_pickup_at']) != null)
              _row(
                'Preferred pickup',
                formatPickupIso(b['preferred_pickup_at']),
              ),
            if (b['pickup_landmark'] != null)
              _row('Notes', b['pickup_landmark']),
            if ('${b['pickup_address'] ?? ''}'.trim().isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => openNavigation(
                    context,
                    lat: lat,
                    lng: lng,
                    address: '${b['pickup_address']}',
                  ),
                  icon: const Icon(Icons.directions),
                  label: const Text('Navigate to pickup'),
                ),
              ),
            const Divider(height: 24),
            Text(
              'Items (${items.length}) · $pending waiting to be received',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            for (final line in items)
              Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${line['quantity']} ${line['unit']} '
                              '${line['item_name']}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Badge2.status('${line['status']}'),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${line['packaging']} · ${line['qr_reference']}'
                        '${line['estimated_value'] != null ? ' · PHP ${line['estimated_value']}' : ''}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Brand.muted,
                        ),
                      ),
                      if (line['actual_quantity_received'] != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'Received: ${line['actual_quantity_received']} ${line['unit']}',
                          ),
                        ),
                      if (line['status'] == 'Pending')
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton.tonalIcon(
                            onPressed: () => _receive(line),
                            icon: const Icon(Icons.move_to_inbox),
                            label: const Text('Receive'),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
