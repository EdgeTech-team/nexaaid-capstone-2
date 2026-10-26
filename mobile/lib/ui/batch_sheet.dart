import 'package:flutter/material.dart';

import 'csws_screens.dart' show ActivityList;
import 'donation_entries_view.dart'
    show BatchHeader, RemovedItemsNote, withBatchHeaders;
import 'expiry_widgets.dart';
import 'input_formatters.dart' show pesos;
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
  // A pop-out with the whole entry, closed with the X (problema_napud 2.1).
  await showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.all(Space.md),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.of(ctx).pop(),
                icon: const Icon(Icons.close),
              ),
            ),
            Flexible(
              child: BatchSheet(Map<String, dynamic>.from(r.json as Map)),
            ),
          ],
        ),
      ),
    ),
  );
}

/// One donation entry: who, for which report and how it is handed over, then
/// every item with its declared quantity and, while pending, an "actual
/// quantity received" field prefilled with the declared quantity.
/// One Receive action receives the whole entry (UC-CM1 alt 4a: less than
/// declared; alt 4b: "Not brought" closes an item that did not arrive).
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

  /// Oct 13 concerns: pending items the donor did not bring. They are
  /// closed on receive ("Not brought to CSWS") instead of staying pending,
  /// so the donation reads Received, never Partly Received.
  final Set<int> _notBrought = {};

  /// Per-item fulfillment (Oct 2026): what an item really is, when the
  /// donor typed "Bigas" or picked the wrong item. donation_id -> the
  /// /lookups item ({id, item_name, unit}). Sent as item_id, so the goods
  /// count toward the matching need (RECLASSIFY DONATION in the audit log).
  final Map<int, Map<String, dynamic>> _itemAs = {};

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
        if (!_notBrought.contains(e.key))
          {
            'donation_id': e.key,
            'actual_quantity': int.parse(e.value.text.trim()),
            if (_itemAs[e.key] != null) 'item_id': _itemAs[e.key]!['id'],
          },
    ];
    setState(() => _busy = true);
    final r = await act(
      context,
      () => api.post(
        '/donations/entries/'
        '${Uri.encodeComponent('${b['batch_reference']}')}/receive',
        body: {
          'items': lines,
          'not_brought': _notBrought.toList(),
          'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        },
      ),
      success: lines.isEmpty
          ? 'Marked as not brought'
          : '${lines.length} item(s) of ${b['batch_reference']} received '
                'and added to inventory'
                '${_notBrought.isEmpty ? '' : '; ${_notBrought.length} not brought'}',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (r.ok) Navigator.of(context).pop(true);
  }

  /// "Wrong item?": CSWS picks what the goods really are. When the unit
  /// changes (sacks -> kg), the amount is cleared so it is typed again in
  /// the new unit.
  Future<void> _changeItem(Map<String, dynamic> line) async {
    final lookups = await api.lookups();
    if (!mounted) return;
    final items = Names(lookups)
        .rows('items')
        .where((i) => '${i['id']}' != '${line['item_id']}')
        .toList();
    final picked = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('What is "${line['item_name']}" really?'),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              'It will count toward the report\'s need for that item.',
              style: TextStyle(fontSize: 13, color: Brand.muted),
            ),
          ),
          for (final i in items)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(i),
              child: Text('${i['item_name'] ?? i['name']} (${i['unit']})'),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    final id = line['donation_id'] as int;
    setState(() {
      _itemAs[id] = picked;
      if ('${picked['unit']}' != '${line['unit']}') _actual[id]?.clear();
    });
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
                  DonationStatusChip('${b['status']}'),
                ],
              ),
              // Deadline, or Expired / Cancelled with the way back.
              if (isClosedEntry(b) ||
                  b['expires_label'] != null ||
                  (b['closed_items'] as num? ?? 0) > 0) ...[
                const SizedBox(height: 10),
                ExpiryNote(b, forStaff: true),
              ],
              // Items the donor removed stay removed, so they do not count.
              if (_items.any(
                (i) =>
                    (i['status'] == 'Expired' || i['status'] == 'Cancelled') &&
                    i['removed_by_donor'] != true,
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
                      if (b['pickup_days_label'] != null)
                        _row(
                          'Pickup days',
                          '${b['pickup_days_label']} · ${b['pickup_hours'] ?? ''}',
                        )
                      else if (doorToDoor ||
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
              // Oct 23: "1 received · 2 pending · 1 removed".
              if (b['summary_text'] != null)
                Text(
                  '${b['summary_text']}',
                  style: const TextStyle(fontSize: 12, color: Brand.muted),
                ),
              if (((b['removed_notes'] as List?) ?? const []).isNotEmpty) ...[
                const SizedBox(height: 8),
                RemovedItemsNote(b),
              ],
              if (pending > 0)
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Text(
                    'Check the goods and enter what was actually received. '
                    'Tap "Not brought" for an item the donor did not bring.',
                    style: TextStyle(fontSize: 12, color: Brand.muted),
                  ),
                ),
              const SizedBox(height: 8),
              // Batch 1 = the original pledge, Batch 2+ = added later. Old
              // donations have one batch and show a plain list.
              for (final (line, header) in withBatchHeaders(items)) ...[
                if (header != null) BatchHeader(header, items: items),
                _itemCard(line),
              ],
              if (pending > 0) ...[
                // problema_napud 4.2: no notes for a guest donation.
                if (b['donor_type'] != 'Guest') ...[
                  TextField(
                    controller: _notes,
                    decoration: const InputDecoration(
                      labelText: 'Notes (optional)',
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                FilledButton.icon(
                  onPressed: _busy ? null : _receive,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  icon: const Icon(Icons.move_to_inbox),
                  label: Text(
                    _notBrought.length == pending
                        ? 'Save: nothing was brought'
                        : 'Receive into inventory',
                  ),
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
              // Oct 23: who added, removed or received what, and when.
              if (((b['history'] as List?) ?? const []).isNotEmpty)
                Theme(
                  data: Theme.of(context)
                      .copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.history),
                    title: Text('History (${(b['history'] as List).length})'),
                    children: [
                      ActivityList((b['history'] as List).cast<Map>()),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _itemCard(Map<String, dynamic> line) {
    final ctrl = _actual[line['donation_id']];
    final relabel = _itemAs[line['donation_id']];
    // Quantities are in the item's base unit (kg, L, pcs). Newer donations
    // also say how the donor described it: "3 x 16 x 1.5 L bottle = 72 L".
    final declared = line['pack_count'] != null && line['amount_text'] != null
        ? '${line['amount_text']}'
        : '${line['quantity']} ${line['unit']} · ${line['packaging']}';
    final unit = '${(relabel ?? line)['unit'] ?? ''}';
    final removed = line['removed_by_donor'] == true;
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
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      decoration: removed ? TextDecoration.lineThrough : null,
                    ),
                  ),
                ),
                if (removed)
                  const StatusChip('Cancelled', label: 'Removed')
                else
                  DonationStatusChip('${line['status']}'),
              ],
            ),
            if (removed)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Removed by the donor: ${line['removed_reason'] ?? ''}',
                  style: const TextStyle(fontStyle: FontStyle.italic),
                ),
              ),
            const SizedBox(height: 4),
            Text(
              'Declared: $declared'
              '${line['estimated_value'] != null ? ' · ${pesos(line['estimated_value'])}' : ''}',
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
            if (ctrl != null) ...[
              if (relabel != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      const Icon(Icons.swap_horiz, size: 18),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Received as ${relabel['item_name'] ?? relabel['name']} '
                          '(${relabel['unit']})',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      TextButton(
                        onPressed: () => setState(() {
                          final id = line['donation_id'] as int;
                          _itemAs.remove(id);
                          if ('${relabel['unit']}' != '${line['unit']}') {
                            ctrl.text = '${line['quantity']}';
                          }
                        }),
                        child: const Text('Undo'),
                      ),
                    ],
                  ),
                ),
              if (!_notBrought.contains(line['donation_id']))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TextFormField(
                    controller: ctrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Actual quantity received',
                      suffixText: unit,
                      isDense: true,
                    ),
                    validator: (v) {
                      final n = int.tryParse(v?.trim() ?? '');
                      if (n == null || n <= 0) {
                        return 'Enter what arrived, or tap "Not brought"';
                      }
                      return null;
                    },
                  ),
                ),
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilterChip(
                    key: ValueKey('not-brought-${line['donation_id']}'),
                    label: const Text('Not brought'),
                    avatar: const Icon(
                      Icons.remove_shopping_cart_outlined,
                      size: 18,
                    ),
                    selected: _notBrought.contains(line['donation_id']),
                    onSelected: (on) => setState(() {
                      final id = line['donation_id'] as int;
                      on ? _notBrought.add(id) : _notBrought.remove(id);
                    }),
                  ),
                  if (!_notBrought.contains(line['donation_id']) &&
                      line['item_id'] != null)
                    TextButton.icon(
                      key: ValueKey('change-item-${line['donation_id']}'),
                      onPressed: () => _changeItem(line),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('Wrong item?'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
