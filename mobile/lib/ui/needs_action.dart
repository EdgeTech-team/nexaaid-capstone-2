import 'package:flutter/material.dart';

import '../api.dart' show ApiResult;
import '../realtime.dart';
import 'widgets.dart';

/// "45 min", "1 h 20 min", "2 days" for the response times.
String spanText(num minutes) {
  final m = minutes.round();
  if (m < 60) return '$m min';
  if (m >= 48 * 60) return '${m ~/ (24 * 60)} days';
  final h = m ~/ 60, rest = m % 60;
  return rest == 0 ? '$h h' : '$h h $rest min';
}

/// Phase 7 (Scope 7.5): how fast DRRMO answers and how long trips take,
/// over the last 30 days (GET /deliveries/timing/summary, from the audit
/// log). Shown on the CSWS and DRRMO home screens.
class ResponseTimesCard extends StatefulWidget {
  const ResponseTimesCard({super.key});

  @override
  State<ResponseTimesCard> createState() => _ResponseTimesCardState();
}

class _ResponseTimesCardState extends State<ResponseTimesCard> {
  Map? _t;

  Future<void> _load() async {
    final r = await api.get('/deliveries/timing/summary');
    if (mounted && r.ok && r.json is Map) setState(() => _t = r.json as Map);
  }

  @override
  void initState() {
    super.initState();
    _load();
    Realtime.instance.logistics.addListener(_load);
  }

  @override
  void dispose() {
    Realtime.instance.logistics.removeListener(_load);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    if (t == null || (t['accepted'] == 0 && t['trips'] == 0)) {
      return const SizedBox.shrink();
    }
    final text = Theme.of(context).textTheme;
    Widget line(
      IconData icon,
      String label,
      num? minutes,
      num count,
      String what,
    ) => ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(label),
      trailing: Text(
        minutes == null ? '-' : spanText(minutes),
        style: text.titleMedium,
      ),
      subtitle: Text('Average of $count $what'),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Response times (last ${t['days']} days)',
              style: text.titleMedium,
            ),
            line(
              Icons.mark_email_read_outlined,
              'Request to accepted',
              t['accept_minutes'] as num?,
              t['accepted'] as num,
              'requests',
            ),
            line(
              Icons.local_shipping_outlined,
              'On the way to arrived',
              t['trip_minutes'] as num?,
              t['trips'] as num,
              'trips',
            ),
          ],
        ),
      ),
    );
  }
}

/// "Needs your action" (GET /deliveries/needs-action) at the top of the CSWS
/// Main Office and DRRMO home screens: what to do next, as counts. Zero
/// counts are hidden; with nothing to do it says "All caught up". Tapping a
/// line calls [onOpen] with it ({key, label, count, view, ids}). Reloads by
/// itself after an action or when a delivery or request changes (live).
class NeedsActionCard extends StatefulWidget {
  final void Function(Map item) onOpen;
  const NeedsActionCard({super.key, required this.onOpen});

  @override
  State<NeedsActionCard> createState() => _NeedsActionCardState();
}

class _NeedsActionCardState extends State<NeedsActionCard> {
  static const _icons = {
    'packing': Icons.inventory_2_outlined,
    'declined': Icons.report_gmailerrorred_outlined,
    'stuck': Icons.warning_amber_rounded,
    'arrived': Icons.where_to_vote_outlined,
    'new': Icons.mark_email_unread_outlined,
    'today': Icons.today_outlined,
    'on_the_way': Icons.local_shipping_outlined,
  };

  List<Map>? _items; // null until the first answer

  Future<void> _load() async {
    final ApiResult r = await api.get('/deliveries/needs-action');
    if (!mounted || !r.ok || r.json is! Map) return;
    setState(() => _items = ((r.json as Map)['items'] as List).cast<Map>());
  }

  @override
  void initState() {
    super.initState();
    _load();
    api.addListener(_load);
    Realtime.instance.logistics.addListener(_load);
  }

  @override
  void dispose() {
    api.removeListener(_load);
    Realtime.instance.logistics.removeListener(_load);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (items == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Needs your action', style: t.titleMedium),
            Gaps.v8,
            if (items.isEmpty)
              Row(
                children: [
                  Icon(Icons.check_circle_outline, color: cs.primary),
                  Gaps.h8,
                  const Expanded(child: Text('All caught up')),
                ],
              ),
            for (final i in items)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: Icon(
                  _icons[i['key']] ?? Icons.flag_outlined,
                  color: i['key'] == 'stuck' || i['key'] == 'declined'
                      ? cs.error
                      : cs.primary,
                ),
                title: Text('${i['label']}'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 13,
                      backgroundColor: cs.primaryContainer,
                      child: Text(
                        '${i['count']}',
                        style: t.labelMedium?.copyWith(
                          color: cs.onPrimaryContainer,
                        ),
                      ),
                    ),
                    const Icon(Icons.chevron_right),
                  ],
                ),
                onTap: () => widget.onOpen(i),
              ),
          ],
        ),
      ),
    );
  }
}
