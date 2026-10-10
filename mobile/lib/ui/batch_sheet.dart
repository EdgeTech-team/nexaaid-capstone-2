import 'package:flutter/material.dart';

import 'expiry_widgets.dart';
import 'location_picker.dart' show formatPickupIso;
import 'pickup_actions.dart';
import 'widgets.dart';

/// UC-CM1 step 2: open a donation entry from its QR or typed reference. One
/// QR covers every item the donor submitted together, so this shows the
/// whole entry. CSWS records the actual quantity of each item and receives
/// them in one go (UC-CM1 steps 3-8, alt 4a/4b) through
/// POST /donations/entries/{batch_reference}/receive.
///
/// Also accepts a per-item reference (DON-XXXX-2) and old single-item QRs.
/// Completes when the sheet is closed, so callers can refresh their lists.
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

/// One donation entry: who, for which report and how it is handed over, then
/// every item with its declared quantity and, while pending, an "actual
/// quantity received" field prefilled with the declared quantity.
/// One Receive action receives the whole entry (UC-CM1 alt 4a: less than
/// declared; alt 4b: 0 = not accepted, the item stays pending).
class BatchSheet extends StatefulWidget {
  final Map<String, dynamic> batch;
  const BatchSheet(this.batch, {super.key});

  @override
  State<BatchSheet> createState() => _BatchSheetState();
}

class _BatchSheetState extends State<BatchSheet> {
  late Map<String, dynamic> b = widget.batch;
  final _form = GlobalKey<FormState>();
  final Map<int, TextEditingController> _actual = {};
  final _notes = TextEditingController();
  bool _busy = false;

  List<Map<String, dynamic>> get _items => (b['items'] as List? ?? const [])
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();

  @override
  void initState() {
    super.initState();
    for (final line in _items.where((i) => i['status'] == 'Pending')) {
      _actual[line['donation_id'] as int] = TextEditingController(
        text: '${line['quantity']}',
      );
    }
  }

  @override
  void dispose() {
    for (final c in _actual.values) {
      c.dispose();
    }
    _notes.dispose();
    super.dispose();
  }

  Future<void> _receive() async {
    if (!_form.currentState!.validate()) return;
    final lines = [
      for (final e in _actual.entries)
        if ((int.tryParse(e.value.text.trim()) ?? 0) > 0)
          {
            'donation_id': e.key,
            'actual_quantity': int.parse(e.value.text.trim()),
          },
    ];
    if (lines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter an actual quantity for at least one item'),
        ),
      );
      return;
    }
    setState(() => _busy = true);
    final r = await act(
      context,
      () => api.post(
        '/donations/entries/'
        '${Uri.encodeComponent('${b['batch_reference']}')}/receive',
        body: {
          'items': lines,
          'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        },
      ),
      success:
          '${lines.length} item(s) of ${b['batch_reference']} received '
          'and added to inventory',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (r.ok) Navigator.of(context).pop(true);
  }

  /// After Reopen / Cancel: load the entry again and show its new state.
  Future<void> _refresh() async {
    final r = await api.get(
      '/donations/by-batch/${Uri.encodeComponent('${b['batch_reference']}')}',
    );
    if (!mounted || !r.ok) return;
    setState(() {
      b = Map<String, dynamic>.from(r.json as Map);
      for (final line in _items.where((i) => i['status'] == 'Pending')) {
        _actual.putIfAbsent(
          line['donation_id'] as int,
          () => TextEditingController(text: '${line['quantity']}'),
        );
      }
      _actual.removeWhere(
        (id, _) => !_items.any(
          (i) => i['donation_id'] == id && i['status'] == 'Pending',
        ),
      );
    });
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
    final doorToDoor = b['handover_method'] == 'Door to Door';
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      child: Form(
        key: _form,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            20,
            0,
            20,
            24 + MediaQuery.of(context).viewInsets.bottom,
          ),
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
              // Deadline, or Expired / Cancelled with the way back.
              if (isClosedEntry(b) ||
                  b['expires_label'] != null ||
                  (b['closed_items'] as num? ?? 0) > 0) ...[
                const SizedBox(height: 10),
                ExpiryNote(b, forStaff: true),
              ],
              if (_items.any(
                (i) => i['status'] == 'Expired' || i['status'] == 'Cancelled',
              ))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    onPressed: () async {
                      if (await reinstateDonation(context, b)) await _refresh();
                    },
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('Reopen so it can be received'),
                  ),
                ),
              const SizedBox(height: 10),
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
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
                      if (b['donor_email'] != null)
                        _row('Email', b['donor_email']),
                      _row('For report', b['report_label']),
                      _row('Handover', b['handover_method']),
                      if (doorToDoor || b['pickup_address'] != null)
                        _row('Pickup at', b['pickup_address']),
                      if (doorToDoor ||
                          formatPickupIso(b['preferred_pickup_at']) != null)
                        _row(
                          'Pickup time',
                          formatPickupIso(b['preferred_pickup_at']),
                        ),
                      if (b['pickup_landmark'] != null)
                        _row('Landmark', b['pickup_landmark']),
                      if (b['pickup_notes'] != null)
                        _row('Notes', b['pickup_notes']),
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
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Items (${items.length}) · $pending waiting to be received',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              if (pending > 0)
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Text(
                    'Check the goods and enter what was actually received. '
                    'Enter 0 for an item that is not accepted; it stays pending.',
                    style: TextStyle(fontSize: 12, color: Brand.muted),
                  ),
                ),
              const SizedBox(height: 8),
              for (final line in items) _itemCard(line),
              if (pending > 0) ...[
                TextField(
                  controller: _notes,
                  decoration: const InputDecoration(
                    labelText: 'Notes (optional)',
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _busy ? null : _receive,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  icon: const Icon(Icons.move_to_inbox),
                  label: const Text('Receive into inventory'),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () async {
                      if (await cancelDonation(context, b, staff: true)) {
                        await _refresh();
                      }
                    },
                    icon: const Icon(Icons.block),
                    label: const Text('Donor cancelled? Cancel it here'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _itemCard(Map<String, dynamic> line) {
    final ctrl = _actual[line['donation_id']];
    return Card(
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
                    '${line['item_name']}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Badge2.status('${line['status']}'),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Declared: ${line['quantity']} ${line['unit']} · '
              '${line['packaging']}'
              '${line['estimated_value'] != null ? ' · PHP ${line['estimated_value']}' : ''}',
            ),
            Text(
              '${line['qr_reference']}',
              style: const TextStyle(fontSize: 12, color: Brand.muted),
            ),
            if (line['actual_quantity_received'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Received: ${line['actual_quantity_received']} ${line['unit']}',
                ),
              ),
            if (ctrl != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: TextFormField(
                  controller: ctrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Actual quantity received',
                    suffixText: '${line['unit'] ?? ''}',
                    isDense: true,
                  ),
                  validator: (v) {
                    final n = int.tryParse(v?.trim() ?? '');
                    if (n == null || n < 0) return 'Enter 0 or more';
                    return null;
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
