import 'package:flutter/material.dart';

import 'widgets.dart';

/// Testing #19: "Scheduled deliveries" on the CSWS Main Office and DRRMO
/// dashboards. Deliveries that have not arrived yet (Active / In Transit),
/// grouped by their delivery date: Overdue, Today, Next 7 days, Later.
/// Each one shows when it reached each step (status_times from #18).
///
/// Data: GET /deliveries/ with [scheduledDeliveriesQuery].
const scheduledDeliveriesQuery = {
  'status': 'Preparing,In Transit',
  'sort': 'date_soonest',
  'limit': '50',
};

class ScheduledDeliveriesCard extends StatelessWidget {
  final List<Map> deliveries;

  /// Tapping a delivery (e.g. open its history). Optional.
  final void Function(Map delivery)? onOpen;

  /// "See all" link to the Deliveries tab. Optional.
  final VoidCallback? onSeeAll;

  const ScheduledDeliveriesCard({
    super.key,
    required this.deliveries,
    this.onOpen,
    this.onSeeAll,
  });

  static DateTime? _date(Map d) =>
      DateTime.tryParse('${d['delivery_date'] ?? ''}')?.toLocal();

  /// Which group a delivery falls in, from its delivery date.
  static String _group(Map d) {
    final when = _date(d);
    if (when == null) return 'Later';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(when.year, when.month, when.day);
    final diff = day.difference(today).inDays;
    if (diff < 0) return d['status'] == 'Preparing' ? 'Overdue' : 'Today';
    if (diff == 0) return 'Today';
    if (diff <= 7) return 'Next 7 days';
    return 'Later';
  }

  @override
  Widget build(BuildContext context) {
    const order = ['Overdue', 'Today', 'Next 7 days', 'Later'];
    final groups = <String, List<Map>>{for (final g in order) g: []};
    for (final d in deliveries) {
      groups[_group(d)]!.add(d);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle(
          'Scheduled deliveries',
          trailing: onSeeAll == null
              ? null
              : TextButton(onPressed: onSeeAll, child: const Text('See all')),
        ),
        if (deliveries.isEmpty)
          const EmptyState('No deliveries are scheduled right now.')
        else
          for (final g in order)
            if (groups[g]!.isNotEmpty) ...[
              _GroupLabel(g, groups[g]!.length),
              for (final d in groups[g]!)
                _ScheduledTile(
                  delivery: d,
                  overdue: g == 'Overdue',
                  onTap: onOpen == null ? null : () => onOpen!(d),
                ),
            ],
      ],
    );
  }
}

class _GroupLabel extends StatelessWidget {
  final String text;
  final int count;
  const _GroupLabel(this.text, this.count);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final overdue = text == 'Overdue';
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
      child: Text(
        '$text ($count)',
        style: t.labelLarge?.copyWith(
          color: overdue ? cs.error : cs.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ScheduledTile extends StatelessWidget {
  final Map delivery;
  final bool overdue;
  final VoidCallback? onTap;
  const _ScheduledTile({
    required this.delivery,
    required this.overdue,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final d = delivery;
    final status = '${d['status'] ?? ''}';
    final barangay = '${d['destination_barangay_name'] ?? '-'}';
    final items = ((d['items'] as List?) ?? const [])
        .cast<Map>()
        .map(
          (i) =>
              '${i['quantity'] ?? ''} ${i['unit'] ?? ''} ${i['item_name'] ?? ''}'
                  .replaceAll(RegExp(r'\s+'), ' ')
                  .trim(),
        )
        .where((s) => s.isNotEmpty)
        .join(', ');
    final times = (d['status_times'] as Map?) ?? const {};

    return AppCard(
      margin: const EdgeInsets.only(bottom: Space.xs),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                overdue ? Icons.warning_amber_rounded : Icons.event_outlined,
                size: 20,
                color: overdue ? cs.error : cs.primary,
              ),
              Gaps.h8,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      niceDate(d['delivery_date']),
                      style: t.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: overdue ? cs.error : null,
                      ),
                    ),
                    Text(
                      'Delivery #${d['delivery_id']} · $barangay',
                      style: t.bodyMedium,
                    ),
                    if (d['report_label'] != null)
                      Text(
                        reportName(d['report_label']),
                        style: t.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              Gaps.h8,
              StatusChip(status),
            ],
          ),
          if (items.isNotEmpty) ...[
            Gaps.v8,
            Text(
              items,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: t.bodySmall,
            ),
          ],
          if (times.isNotEmpty) ...[
            Gaps.v8,
            Wrap(
              spacing: Space.sm,
              runSpacing: Space.xxs,
              children: [
                for (final e in times.entries)
                  Text(
                    '${StatusColors.label('${e.key}')} ${_clock(e.value)}',
                    style: t.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// "Oct 26 9:05 AM" for a status time.
  static String _clock(dynamic iso) {
    final d = DateTime.tryParse('${iso ?? ''}')?.toLocal();
    if (d == null) return '';
    const m = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final mm = d.minute.toString().padLeft(2, '0');
    return '${m[d.month - 1]} ${d.day} $h:$mm ${d.hour < 12 ? 'AM' : 'PM'}';
  }
}
