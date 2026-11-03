import 'package:flutter/material.dart';

import 'delivery_widgets.dart' show DateField, niceWhen, pickDeliveryDateTime;
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

/// Note lines DRRMO adds when accepting; the card shows them on their own.
const _drrmoLines = ['DRRMO vehicle: ', 'DRRMO driver: '];

/// "Truck 2 · Driver: Juan" from a request row, or null if neither was given.
String? vehicleAndDriver(Map r) {
  final parts = [
    if (r['vehicle'] != null) '${r['vehicle']}',
    if (r['driver'] != null) 'Driver: ${r['driver']}',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// UC-DR1 step 5 / Table 36 alt 4a: DRRMO accepts a delivery request and says
/// when its truck comes, with date and time pickers (no typing). Vehicle and
/// driver are optional. Starts at the time Main Office planned, if it has not
/// passed. Returns the body for PATCH /drrmo/requests/{id}/accept, or null.
Future<Map<String, dynamic>?> showAcceptDeliveryDialog(
  BuildContext context,
  Map r,
) => showDialog<Map<String, dynamic>>(
  context: context,
  builder: (_) => _AcceptDeliveryDialog(r),
);

class _AcceptDeliveryDialog extends StatefulWidget {
  final Map r;
  const _AcceptDeliveryDialog(this.r);

  @override
  State<_AcceptDeliveryDialog> createState() => _AcceptDeliveryDialogState();
}

class _AcceptDeliveryDialogState extends State<_AcceptDeliveryDialog> {
  final _vehicle = TextEditingController();
  final _driver = TextEditingController();
  String? _when; // ISO, UTC
  String? _error;

  @override
  void initState() {
    super.initState();
    final planned = DateTime.tryParse('${widget.r['scheduled_date'] ?? ''}');
    if (planned != null && planned.isAfter(DateTime.now())) {
      _when = planned.toUtc().toIso8601String();
    }
  }

  @override
  void dispose() {
    _vehicle.dispose();
    _driver.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final v = await pickDeliveryDateTime(
      context,
      current: _when ?? '${widget.r['scheduled_date'] ?? ''}',
      help: 'When will DRRMO pick up the goods?',
    );
    if (v != null && mounted) {
      setState(() {
        _when = v;
        _error = null;
      });
    }
  }

  void _accept() {
    final at = DateTime.tryParse(_when ?? '');
    if (at == null) {
      setState(() => _error = 'Pick the date and time');
      return;
    }
    // Same 5 minutes of grace as the server (AcceptLogisticsRequest).
    if (at.isBefore(DateTime.now().subtract(const Duration(minutes: 5)))) {
      setState(() => _error = 'This time has passed. Pick a later one.');
      return;
    }
    Navigator.pop(context, {
      'scheduled_date': _when,
      if (_vehicle.text.trim().isNotEmpty) 'vehicle': _vehicle.text.trim(),
      if (_driver.text.trim().isNotEmpty) 'driver': _driver.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.r;
    final t = Theme.of(context).textTheme;
    return AlertDialog(
      title: Text('Accept request #${r['request_id']}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('${r['needs'] ?? 'Transport support'}', style: t.titleSmall),
            Text('To ${r['destination'] ?? '-'}'),
            if (r['scheduled_date'] != null)
              Text(
                'CSWS planned it for ${niceWhen(r['scheduled_date'])}',
                style: t.bodySmall,
              ),
            Gaps.v12,
            DateField(
              label: 'When DRRMO picks up the goods',
              value: _when,
              error: _error,
              onTap: _pick,
            ),
            Gaps.v12,
            TextField(
              controller: _vehicle,
              maxLength: 80,
              decoration: const InputDecoration(
                labelText: 'Vehicle (optional)',
                hintText: 'e.g. Truck 2, ABC-123',
                prefixIcon: Icon(Icons.local_shipping_outlined),
              ),
            ),
            TextField(
              controller: _driver,
              maxLength: 80,
              decoration: const InputDecoration(
                labelText: 'Driver (optional)',
                prefixIcon: Icon(Icons.person_outline),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _accept,
          icon: const Icon(Icons.check),
          label: const Text('Accept'),
        ),
      ],
    );
  }
}

class LogisticsRequestCard extends StatelessWidget {
  final Map r;

  /// Buttons for this request (Accept, Decline, ...), shown at the bottom.
  final List<Widget> actions;

  /// Tapping the card (not a button), e.g. the delivery's timeline.
  final VoidCallback? onTap;

  const LogisticsRequestCard(
    this.r, {
    super.key,
    this.actions = const [],
    this.onTap,
  });

  bool get _pickup => r['request_type'] == 'Pickup';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final needs = '${r['needs'] ?? ''}'.trim();
    final other = '${r['notes'] ?? ''}'
        .split('\n')
        .where(
          (l) =>
              l.trim().isNotEmpty &&
              l.trim() != needs &&
              !_drrmoLines.any(l.startsWith),
        )
        .join('\n');
    final byDrrmo = r['scheduled_by'] == 'DRRMO';
    final truck = vehicleAndDriver(r);
    final goods = (r['goods'] as List? ?? const []).map((e) => '$e').toList();
    final stops = (r['stops'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final who = r['requested_by_role'] == 'CSWS Disaster Unit'
        ? 'CSWS Disaster Unit'
        : 'CSWS Main Office';

    return AppCard(
      onTap: onTap,
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
              StatusChip(
                '${r['stage'] ?? r['status']}',
                label: r['stage'] == 'In Transit' ? 'On the way' : null,
              ),
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
            // Testing (Oct 23): DRRMO sees what is in the prepared delivery,
            // one line per item, so they know what the truck will carry.
            Gaps.v8,
            Text('Items to load (${goods.length})', style: t.titleSmall),
            Gaps.v4,
            for (final g in goods)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.inventory_2_outlined,
                      size: 18,
                      color: cs.primary,
                    ),
                    Gaps.h8,
                    Expanded(child: Text(g, style: t.bodyMedium)),
                  ],
                ),
              ),
          ],
          // Main Office plans the date; once DRRMO accepted, it is DRRMO's
          // time (UC-DR1 step 5). A pickup run shows its pickup day above.
          if (!_pickup && r['scheduled_date'] != null) ...[
            Gaps.v4,
            Row(
              children: [
                Icon(Icons.event_outlined, size: 16, color: cs.primary),
                Gaps.h4,
                Expanded(
                  child: Text(
                    byDrrmo
                        ? 'DRRMO comes ${niceWhen(r['scheduled_date'])}'
                        : 'Planned by CSWS Main Office: '
                              '${niceWhen(r['scheduled_date'])}',
                    style: byDrrmo
                        ? const TextStyle(fontWeight: FontWeight.w700)
                        : null,
                  ),
                ),
              ],
            ),
          ],
          if (truck != null) ...[
            Gaps.v4,
            Row(
              children: [
                Icon(
                  Icons.local_shipping_outlined,
                  size: 16,
                  color: cs.primary,
                ),
                Gaps.h4,
                Expanded(child: Text(truck)),
              ],
            ),
          ],
          // Testing fix 7.5: why DRRMO cannot mark a pickup run completed
          // yet. A delivery request completes itself on arrival (Table 36).
          if (_pickup && r['complete_blocker'] != null) ...[
            Gaps.v4,
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_clock_outlined, size: 16, color: cs.error),
                Gaps.h4,
                Expanded(
                  child: Text(
                    '${r['complete_blocker']}',
                    style: t.bodySmall?.copyWith(color: cs.error),
                  ),
                ),
              ],
            ),
          ],
          if (other.isNotEmpty) ...[
            Gaps.v8,
            Text(
              other,
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
          if (onTap != null) ...[
            Gaps.v8,
            Row(
              children: [
                Icon(Icons.timeline, size: 16, color: cs.primary),
                Gaps.h4,
                Expanded(
                  child: Text(
                    'Tap the card for the delivery timeline',
                    style: t.bodySmall?.copyWith(color: cs.primary),
                  ),
                ),
              ],
            ),
          ],
          if (actions.isNotEmpty) ...[
            Gaps.v12,
            _Actions(actions),
          ],
        ],
      ),
    );
  }
}

/// A card's buttons. On a phone two buttons (Decline / Accept) share the
/// row at full width, so they are big and easy to hit; otherwise they sit
/// at the end of the card and wrap.
class _Actions extends StatelessWidget {
  final List<Widget> actions;
  const _Actions(this.actions);

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final buttonsOnly = actions.every((a) => a is ButtonStyleButton);
      if (c.maxWidth < 480 && buttonsOnly && actions.length <= 2) {
        return Row(
          children: [
            for (var i = 0; i < actions.length; i++) ...[
              if (i > 0) Gaps.h8,
              Expanded(child: actions[i]),
            ],
          ],
        );
      }
      return Wrap(
        alignment: WrapAlignment.end,
        spacing: Space.xs,
        runSpacing: 6,
        children: actions,
      );
    },
  );
}
