import 'package:flutter/material.dart';

import 'pickup_actions.dart' show openNavigation;
import 'widgets.dart';

// ---------------------------------------------------------------------------
// One DRRMO logistics request (UC-DR1), for a delivery (CSWS Main Office) or
// a Door to Door pickup run (CSWS Disaster Unit).
//
// Appendix H 7.2 (Oct 10 notes): what is requested and when it was
// requested stand out at the top of the card, so DRRMO reads them first.
// ---------------------------------------------------------------------------

const _wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _mo = [
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

/// "Tue, Oct 13 · 2:30 PM" in Philippine time.
String requestWhen(Object? iso) {
  final d = DateTime.tryParse('${iso ?? ''}');
  if (d == null) return '-';
  final ph = d.toUtc().add(const Duration(hours: 8));
  final h = ph.hour % 12 == 0 ? 12 : ph.hour % 12;
  final m = ph.minute.toString().padLeft(2, '0');
  return '${_wd[ph.weekday - 1]}, ${_mo[ph.month - 1]} ${ph.day} · '
      '$h:$m ${ph.hour < 12 ? 'AM' : 'PM'}';
}

/// "Wed, Oct 14" from "2026-10-14".
String pickupDay(Object? ymd) {
  final d = DateTime.tryParse('${ymd ?? ''}');
  if (d == null) return '-';
  return '${_wd[d.weekday - 1]}, ${_mo[d.month - 1]} ${d.day}';
}

class LogisticsRequestCard extends StatelessWidget {
  final Map r;

  /// Buttons for this request (Accept, Decline, ...), shown at the bottom.
  final List<Widget> actions;

  const LogisticsRequestCard(this.r, {super.key, this.actions = const []});

  bool get _pickup => r['request_type'] == 'Pickup';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final needs = '${r['needs'] ?? ''}'.trim();
    final other = '${r['notes'] ?? ''}'
        .split('\n')
        .where((l) => l.trim().isNotEmpty && l.trim() != needs)
        .join('\n');
    final goods = (r['goods'] as List? ?? const []).map((e) => '$e').toList();
    final stops = (r['stops'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final who = r['requested_by_role'] == 'CSWS Disaster Unit'
        ? 'CSWS Disaster Unit'
        : 'CSWS Main Office';

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // What kind of request, and its status.
          Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: _pickup
                    ? AppColors.vest.withValues(alpha: 0.25)
                    : cs.primaryContainer,
                child: Icon(
                  _pickup
                      ? Icons.door_front_door_outlined
                      : Icons.local_shipping_outlined,
                  size: 20,
                  color: _pickup ? AppColors.vestInk : cs.onPrimaryContainer,
                ),
              ),
              Gaps.h12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _pickup
                          ? 'Request #${r['request_id']} · Pickup run'
                          : 'Request #${r['request_id']} · Delivery',
                      style: t.titleMedium,
                    ),
                    Text(
                      _pickup
                          ? '${r['destination'] ?? ''}'
                          : 'To ${r['destination'] ?? '-'}',
                      style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              StatusChip('${r['stage'] ?? r['status']}'),
            ],
          ),
          Gaps.v12,

          // 7.2: the request and when it was made, highlighted.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(Space.sm),
            decoration: BoxDecoration(
              color: cs.primaryContainer.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(Radii.md),
              border: Border(left: BorderSide(color: cs.primary, width: 4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.handshake_outlined, size: 20, color: cs.primary),
                    Gaps.h8,
                    Expanded(
                      child: Text(
                        needs.isEmpty ? 'Transport support' : needs,
                        style: t.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: cs.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
                Gaps.v8,
                Row(
                  children: [
                    Icon(Icons.schedule, size: 18, color: cs.primary),
                    Gaps.h8,
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            const TextSpan(text: 'Requested '),
                            TextSpan(
                              text: requestWhen(r['created_at']),
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            TextSpan(text: ' by $who'),
                          ],
                        ),
                        style: t.bodyMedium?.copyWith(
                          color: cs.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
                if (_pickup && r['pickup_date'] != null) ...[
                  Gaps.v8,
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Space.xs + 2,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.vest,
                      borderRadius: BorderRadius.circular(Radii.pill),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.event,
                          size: 16,
                          color: AppColors.vestInk,
                        ),
                        Gaps.h4,
                        Text(
                          'Pickup on ${pickupDay(r['pickup_date'])}',
                          style: t.labelLarge?.copyWith(
                            color: AppColors.vestInk,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          Gaps.v12,

          if (r['priority_level'] != null || r['report_label'] != null)
            Row(
              children: [
                if (r['priority_level'] != null) ...[
                  PriorityChip('${r['priority_level']}'),
                  Gaps.h8,
                ],
                if (!_pickup)
                  Expanded(
                    child: Text(
                      '${r['report_label'] ?? ''}',
                      style: t.bodyMedium,
                    ),
                  ),
              ],
            ),
          if (_pickup && stops.isNotEmpty)
            Theme(
              data: Theme.of(context)
                  .copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                initiallyExpanded: stops.length <= 3,
                title: Text(
                  '${stops.length} stop${stops.length == 1 ? '' : 's'}, in order',
                  style: t.titleSmall,
                ),
                children: [
                  for (final s in stops)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        radius: 13,
                        backgroundColor: cs.primary,
                        child: Text(
                          '${s['stop']}',
                          style: t.labelMedium?.copyWith(color: cs.onPrimary),
                        ),
                      ),
                      title: Text(
                        '${s['landmark'] ?? s['address'] ?? s['batch_reference']}',
                      ),
                      subtitle: Text(
                        [
                          if (s['landmark'] != null && s['address'] != null)
                            '${s['address']}',
                          ...(s['goods'] as List? ?? const []).map((g) => '$g'),
                        ].join(' · '),
                      ),
                      trailing: IconButton(
                        tooltip: 'Directions',
                        icon: const Icon(Icons.directions),
                        onPressed: () => openNavigation(
                          context,
                          lat: (s['lat'] as num?)?.toDouble(),
                          lng: (s['lng'] as num?)?.toDouble(),
                          address: '${s['address'] ?? ''}',
                        ),
                      ),
                    ),
                ],
              ),
            )
          else if (goods.isNotEmpty) ...[
            Gaps.v8,
            Text('Goods: ${goods.join(', ')}', style: t.bodyMedium),
          ],
          if (r['scheduled_date'] != null) ...[
            Gaps.v4,
            Text('Scheduled: ${niceDate(r['scheduled_date'])}'),
          ],
          if (other.isNotEmpty) ...[
            Gaps.v8,
            Text(
              other,
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
          if (actions.isNotEmpty) ...[
            Gaps.v8,
            Wrap(
              alignment: WrapAlignment.end,
              spacing: Space.xs,
              runSpacing: 6,
              children: actions,
            ),
          ],
        ],
      ),
    );
  }
}
