// J1 / NF-009 (team agreement Nov 18, 2026): the Barangay Receiving
// Representative counts every item before confirming receipt (UC-B1).
//
// Every count field starts empty. When a count differs from what CSWS sent,
// a reason is needed: "Over" when more arrived; Short, Damaged or Wrong item
// when fewer arrived; none when it matches. The server checks the same rules
// (POST /deliveries/{id}/confirm-receipt and POST /trips/{id}/confirm-receipt).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/design.dart';

/// Reasons for a count lower than what CSWS sent.
const shortReasons = ['Short', 'Damaged', 'Wrong item'];

/// The only reason for a count higher than what CSWS sent.
const overReason = 'Over';

/// The reasons that fit [received] against [sent]; empty when they match.
List<String> reasonsFor(int received, int sent) {
  if (received < sent) return shortReasons;
  if (received > sent) return const [overReason];
  return const [];
}

/// One delivery to count: its number, a title and its lines as
/// GET /deliveries/ sends them (delivery_item_id, quantity, item_name, unit).
class CountTarget {
  final int deliveryId;
  final String title;
  final List<Map> lines;
  const CountTarget(this.deliveryId, this.title, this.lines);

  factory CountTarget.fromDelivery(Map d) => CountTarget(
    d['delivery_id'] as int,
    'Delivery #${d['delivery_id']}',
    (d['items'] as List? ?? const []).cast<Map>(),
  );
}

/// What the rep counted, ready to send.
class ReceiptCounts {
  /// delivery_id -> the "items" list of its request body.
  final Map<int, List<Map<String, dynamic>>> items;
  final String? remarks;

  /// At least one line differs from what CSWS sent.
  final bool hasDifference;

  const ReceiptCounts(this.items, this.remarks, {required this.hasDifference});

  /// Body for POST /deliveries/{id}/confirm-receipt.
  Map<String, dynamic> deliveryBody(int deliveryId) => {
    'items': items[deliveryId] ?? const [],
    if (remarks != null) 'remarks': remarks,
  };

  /// Body for POST /trips/{id}/confirm-receipt.
  Map<String, dynamic> tripBody() => {
    'deliveries': [
      for (final e in items.entries) {'delivery_id': e.key, 'items': e.value},
    ],
    if (remarks != null) 'remarks': remarks,
  };
}

/// Shows the count form for [deliveries]: one delivery, or every delivery of
/// a trip that arrived at the barangay. Returns the counts, or null if
/// cancelled.
Future<ReceiptCounts?> showReceiptCountDialog(
  BuildContext context, {
  required String title,
  String? message,
  required List<CountTarget> deliveries,
}) => showDialog<ReceiptCounts>(
  context: context,
  builder: (_) => ReceiptCountDialog(
    title: title,
    message: message,
    deliveries: deliveries,
  ),
);

class ReceiptCountDialog extends StatefulWidget {
  final String title;
  final String? message;
  final List<CountTarget> deliveries;
  const ReceiptCountDialog({
    super.key,
    required this.title,
    this.message,
    required this.deliveries,
  });

  @override
  State<ReceiptCountDialog> createState() => _ReceiptCountDialogState();
}

/// One line being counted.
class _Line {
  final int id;
  final int sent;
  final String name;
  final String unit;
  final count = TextEditingController(); // starts empty: no default count
  final note = TextEditingController();
  String? reason;

  _Line(Map m)
    : id = m['delivery_item_id'] as int,
      sent = (m['quantity'] as num).toInt(),
      name = '${m['item_name'] ?? 'Item #${m['item_id']}'}',
      unit = '${m['unit'] ?? ''}';

  int? get received => int.tryParse(count.text.trim());

  List<String> get fits {
    final r = received;
    return r == null ? const [] : reasonsFor(r, sent);
  }

  String amount(int n) => '$n $unit'.trim();
}

class _ReceiptCountDialogState extends State<ReceiptCountDialog> {
  final _form = GlobalKey<FormState>();
  final _remarks = TextEditingController();
  late final Map<int, List<_Line>> _lines = {
    for (final t in widget.deliveries)
      t.deliveryId: [for (final m in t.lines) _Line(m)],
  };

  @override
  void dispose() {
    for (final l in _lines.values.expand((x) => x)) {
      l.count.dispose();
      l.note.dispose();
    }
    _remarks.dispose();
    super.dispose();
  }

  /// A new count: drop a reason that no longer fits (e.g. Short -> Over).
  void _counted(_Line l) => setState(() {
    if (!l.fits.contains(l.reason)) l.reason = null;
  });

  void _confirm() {
    if (!_form.currentState!.validate()) return;
    var differs = false;
    final items = <int, List<Map<String, dynamic>>>{};
    for (final e in _lines.entries) {
      items[e.key] = [
        for (final l in e.value)
          {
            'delivery_item_id': l.id,
            'received_quantity': l.received,
            if (l.received != l.sent) ...{
              'discrepancy_reason': l.reason,
              if (l.note.text.trim().isNotEmpty)
                'discrepancy_note': l.note.text.trim(),
            },
          },
      ];
      differs = differs || e.value.any((l) => l.received != l.sent);
    }
    final remarks = _remarks.text.trim();
    Navigator.pop(
      context,
      ReceiptCounts(
        items,
        remarks.isEmpty ? null : remarks,
        hasDifference: differs,
      ),
    );
  }

  Widget _lineFields(BuildContext context, _Line l) {
    final t = Theme.of(context).textTheme;
    final fits = l.fits;
    final direction = fits.isEmpty
        ? 'same'
        : (fits.first == overReason ? 'over' : 'short');
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.name, style: t.titleSmall),
          Text('Sent by CSWS: ${l.amount(l.sent)}', style: t.bodySmall),
          Gaps.v4,
          TextFormField(
            key: Key('count-${l.id}'),
            controller: l.count,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(9),
            ],
            decoration: InputDecoration(
              labelText: 'Received${l.unit.isEmpty ? '' : ' (${l.unit})'}',
              hintText: 'Count it',
            ),
            onChanged: (_) => _counted(l),
            validator: (v) => (v ?? '').trim().isEmpty
                ? 'Enter the number you counted'
                : null,
          ),
          if (fits.isNotEmpty) ...[
            Gaps.v8,
            DropdownButtonFormField<String>(
              // A new key when the count turns from fewer to more (or back),
              // so the menu shows only the reasons that fit.
              key: ValueKey('reason-${l.id}-$direction'),
              initialValue: l.reason,
              items: [
                for (final r in fits)
                  DropdownMenuItem(value: r, child: Text(r)),
              ],
              onChanged: (v) => setState(() => l.reason = v),
              decoration: InputDecoration(
                labelText: 'Why is it different?',
                helperText:
                    'You counted ${l.amount(l.received!)}; '
                    'CSWS sent ${l.amount(l.sent)}.',
              ),
              validator: (v) => v == null ? 'Choose a reason' : null,
            ),
            Gaps.v8,
            TextFormField(
              key: Key('note-${l.id}'),
              controller: l.note,
              maxLength: 500,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final many = widget.deliveries.length > 1;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.message != null) ...[
                  Text(widget.message!),
                  Gaps.v12,
                ],
                for (final target in widget.deliveries) ...[
                  if (many)
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 8),
                      child: Text(target.title, style: t.titleMedium),
                    ),
                  for (final l in _lines[target.deliveryId]!)
                    _lineFields(context, l),
                ],
                TextFormField(
                  key: const Key('remarks'),
                  controller: _remarks,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Remarks (optional)',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('confirm-counts'),
          onPressed: _confirm,
          child: Text(many ? 'Confirm all' : 'Confirm receipt'),
        ),
      ],
    );
  }
}

/// On a delivery card: the lines the barangay counted differently, e.g.
/// "Barangay count differs: Rice: 40 of 50 kg (Short)". Nothing when every
/// count matched or nothing was counted yet.
class ReceiptDifferences extends StatelessWidget {
  final Map delivery;
  const ReceiptDifferences(this.delivery, {super.key});

  static String _line(Map it) {
    final sent = '${it['quantity']} ${it['unit'] ?? ''}'.trim();
    final why = it['discrepancy_reason'] != null
        ? ' (${it['discrepancy_reason']})'
        : '';
    return '${it['item_name'] ?? 'Item'}: ${it['received_quantity']} of $sent$why';
  }

  @override
  Widget build(BuildContext context) {
    final lines = [
      for (final it in (delivery['items'] as List? ?? const []).cast<Map>())
        if (it['received_quantity'] != null &&
            it['received_quantity'] != it['quantity'])
          _line(it),
    ];
    if (lines.isEmpty) return const SizedBox.shrink();
    final color = Theme.of(context).colorScheme.error;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.report_problem_outlined, size: 16, color: color),
          Gaps.h4,
          Expanded(
            child: Text(
              'Barangay count differs: ${lines.join('; ')}',
              style: TextStyle(fontSize: 12, color: color),
            ),
          ),
        ],
      ),
    );
  }
}
