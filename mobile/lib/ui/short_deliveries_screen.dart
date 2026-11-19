// J5 / NF-010 (team agreement Nov 18, 2026, A3): CSWS shortfall review.
//
// A short delivery is a Confirmed delivery where the Barangay Receiving
// Representative counted less than CSWS sent on at least one line. CSWS Main
// Office records why (one of four causes, with an optional note). The
// Administrator sees the same list but cannot review.
//
// A review only records the cause: it does not change stock, fulfillment or
// priority. Office miscounts are fixed with the inventory adjustment.
import 'package:flutter/material.dart';

import '../api.dart' show ApiResult, Roles;
import 'delivery_widgets.dart' show niceWhen;
import 'paginated_list.dart';
import 'widgets.dart';

/// The causes, exactly as the backend accepts them.
const shortfallCauses = [
  'Damaged',
  'Lost in transit',
  'Miscount at office',
  'Miscount at barangay',
];

/// Opens the short deliveries list (CSWS Main Office and Administrator).
Future<void> openShortDeliveries(BuildContext context) =>
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const ShortDeliveriesScreen()));

class ShortDeliveriesScreen extends StatefulWidget {
  const ShortDeliveriesScreen({super.key});

  @override
  State<ShortDeliveriesScreen> createState() => _ShortDeliveriesScreenState();
}

class _ShortDeliveriesScreenState extends State<ShortDeliveriesScreen> {
  /// Only CSWS Main Office reviews; the Administrator only reads.
  final bool canReview = api.role == Roles.cswsMain;

  /// false = still to review, true = reviewed, null = all.
  late bool? reviewed = canReview ? false : null;

  late final c = PagedController(fetch: _fetch);

  Future<ApiResult> _fetch(int offset, int limit) => api.get(
    '/deliveries/discrepancies',
    query: {
      'limit': '$limit',
      'offset': '$offset',
      if (reviewed != null) 'reviewed': '$reviewed',
    },
  );

  void _show(bool? v) {
    if (v == reviewed) return;
    setState(() => reviewed = v);
    c.refresh(fetch: _fetch);
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Short deliveries')),
      body: PagedListView(
        controller: c,
        padding: const EdgeInsets.all(Space.md),
        header: [
          Text(
            canReview
                ? 'Deliveries the barangay counted short. Record why; this '
                      'does not change stock, fulfillment or priority.'
                : 'Deliveries the barangay counted short, and the cause '
                      'CSWS Main Office recorded.',
            style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          Gaps.v12,
          Wrap(
            spacing: Space.xs,
            runSpacing: Space.xs,
            children: [
              for (final e in const {
                false: 'Not reviewed',
                true: 'Reviewed',
                null: 'All',
              }.entries)
                ChoiceChip(
                  label: Text(e.value),
                  selected: reviewed == e.key,
                  onSelected: (_) => _show(e.key),
                ),
            ],
          ),
          Gaps.v12,
        ],
        empty: EmptyState(
          reviewed == false
              ? 'No short delivery to review'
              : 'No short deliveries',
          icon: Icons.fact_check_outlined,
        ),
        itemBuilder: (context, d) => ShortDeliveryCard(
          d,
          onReview: canReview
              ? () => reviewShortfall(context, d, onDone: c.reloadQuietly)
              : null,
        ),
      ),
    );
  }
}

/// One short delivery: the short lines with the barangay's reason, and the
/// review. [onReview] is null when the viewer cannot review.
class ShortDeliveryCard extends StatelessWidget {
  final Map d;
  final VoidCallback? onReview;
  const ShortDeliveryCard(this.d, {super.key, this.onReview});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final cause = d['cause'] as String?;
    final lines = (d['short_lines'] as List? ?? const []).cast<Map>();
    String qty(Map l, String key) =>
        [l[key], l['unit']].where((v) => v != null).join(' ');
    return AppCard(
      margin: const EdgeInsets.only(bottom: Space.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Delivery #${d['delivery_id']} · ${d['barangay_name'] ?? ''}',
            style: t.titleMedium,
          ),
          if (d['report_label'] != null) Text('${d['report_label']}'),
          if (d['received_at'] != null)
            Text(
              'Received ${niceWhen(d['received_at'])}',
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          Gaps.v8,
          for (final l in lines) ...[
            Text(
              '${l['item_name']}: sent ${qty(l, 'expected_quantity')} · '
              'received ${qty(l, 'received_quantity')}',
            ),
            if (l['discrepancy_reason'] != null)
              Text(
                [
                  'Barangay: ${l['discrepancy_reason']}',
                  if ((l['discrepancy_note'] ?? '').toString().isNotEmpty)
                    l['discrepancy_note'],
                ].join(' · '),
                style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            Gaps.v4,
          ],
          const Divider(),
          if (cause == null)
            Text(
              'Not reviewed yet',
              style: t.labelLarge?.copyWith(color: cs.error),
            )
          else ...[
            Text('Cause: $cause', style: t.labelLarge),
            if ((d['note'] ?? '').toString().isNotEmpty) Text('${d['note']}'),
            Text(
              [
                if (d['reviewed_by'] != null) 'Reviewed by ${d['reviewed_by']}',
                if (d['reviewed_at'] != null) niceWhen(d['reviewed_at']),
              ].join(' · '),
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
          if (onReview != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onReview,
                icon: const Icon(Icons.rate_review_outlined),
                label: Text(cause == null ? 'Review' : 'Change cause'),
              ),
            ),
        ],
      ),
    );
  }
}

/// The review dialog: one of the four causes and an optional note. Saves
/// with POST /deliveries/{id}/discrepancy-review, then calls [onDone].
Future<void> reviewShortfall(
  BuildContext context,
  Map d, {
  required VoidCallback onDone,
}) async {
  final id = d['delivery_id'];
  final current = d['cause'] as String?;
  final v = await formDialog(
    context,
    title: 'Review delivery #$id',
    message:
        'Why did this delivery come up short? This records the cause only; '
        'it does not change stock, fulfillment or priority.',
    fields: [
      DialogField(
        'cause',
        'Cause',
        options: ['', ...shortfallCauses],
        initial: shortfallCauses.contains(current) ? current! : '',
      ),
      DialogField(
        'note',
        'Note (optional)',
        initial: (d['note'] ?? '').toString(),
        required: false,
        multiline: true,
      ),
    ],
    confirm: 'Save review',
  );
  if (v == null || !context.mounted) return;
  final cause = v['cause'] ?? '';
  if (cause.isEmpty) {
    AppToast.showOn(
      Overlay.of(context, rootOverlay: true),
      'Pick a cause to save the review.',
      kind: ToastKind.error,
    );
    return;
  }
  final note = v['note'] ?? '';
  final r = await act(
    context,
    () => api.post(
      '/deliveries/$id/discrepancy-review',
      body: {'cause': cause, if (note.isNotEmpty) 'note': note},
    ),
    success: 'Review saved for delivery #$id',
  );
  if (r.ok) onDone();
}
