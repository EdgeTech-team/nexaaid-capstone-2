import 'package:flutter/material.dart';

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

// Defense fixes (Nov 23): "Needs your action" is removed for every role,
// the CMO included (its Acknowledge tiles already show the counts).
