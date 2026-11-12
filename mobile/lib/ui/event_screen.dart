import 'package:flutter/material.dart';

import 'disaster_art.dart';
import 'donor_screens.dart' show DonateScreen;
import 'notifications_screen.dart' show showReportSheet;
import 'report_summary_card.dart' show NeedChips;
import 'widgets.dart';

// ---------------------------------------------------------------------------
// NF-003 (Nov 2026): a disaster that hit several barangays is ONE card for
// donors. Tapping it opens the event page: every barangay with its own
// progress, lowest first, and a Donate button on each one that still needs
// help. A donation still goes to one barangay's report.
// ---------------------------------------------------------------------------

num _pct(Map r) => (r['fulfillment_percentage'] as num?) ?? 0;

/// The validated reports of one event, from /lookups `validated_reports`.
List<Map<String, dynamic>> eventReports(
  List<Map<String, dynamic>> validated,
  Object? eventId,
) => [
  if (eventId != null)
    for (final r in validated)
      if ('${r['event_id']}' == '$eventId') r,
];

/// Event % for donors: the reports' official % weighted by affected
/// families (same rule as GET /reports/events/{id}).
double eventPercent(List<Map> reports) {
  var weight = 0;
  var total = 0.0;
  for (final r in reports) {
    final f = (r['affected_families'] as num?)?.toInt() ?? 0;
    weight += f;
    total += _pct(r) * f;
  }
  return weight == 0 ? 0 : total / weight;
}

/// The "Barangays that need help" list with each event's reports folded
/// into its first (most urgent) one. Event rows get `event_reports` (every
/// validated report of the event); single reports stay as they are.
List<Map<String, dynamic>> foldEvents(
  List<Map<String, dynamic>> open,
  List<Map<String, dynamic>> validated,
) {
  final seen = <String>{};
  return [
    for (final r in open)
      if (r['event_id'] == null)
        r
      else if (seen.add('${r['event_id']}'))
        {...r, 'event_reports': eventReports(validated, r['event_id'])},
  ];
}

/// Opens the event page of a report that belongs to an event.
void openEvent(BuildContext context, Map report) => Navigator.of(context).push(
  MaterialPageRoute(
    builder: (_) => EventScreen(eventId: (report['event_id'] as num).toInt()),
  ),
);

/// "1 barangay", "3 barangays".
String barangaysText(int n) => n == 1 ? '1 barangay' : '$n barangays';

/// Under a report that is part of an event (report lists, details,
/// notifications, the guest pop-out): the event's name and a way to see
/// every barangay of the same disaster. Nothing for a single report.
class EventLink extends StatelessWidget {
  final Map report;
  const EventLink(this.report, {super.key});

  @override
  Widget build(BuildContext context) {
    if (report['event_id'] == null) return const SizedBox.shrink();
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: Space.xxs),
      child: Row(
        children: [
          Icon(Icons.share_location_outlined, size: 16, color: cs.primary),
          Gaps.h4,
          Expanded(
            child: Text(
              'Part of ${report['event_name'] ?? 'a disaster in several barangays'}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: t.bodySmall,
            ),
          ),
          TextButton(
            key: ValueKey('see-event-${report['event_id']}'),
            onPressed: () => openEvent(context, report),
            child: const Text('See all barangays'),
          ),
        ],
      ),
    );
  }
}

/// One card for a whole event: name, barangays, families, event progress,
/// and "Choose a barangay" (yellow: it leads to Donate).
class EventNeedCard extends StatelessWidget {
  final Map<String, dynamic> report; // a folded row (see foldEvents)
  final VoidCallback onOpen;
  final double width;
  const EventNeedCard({
    super.key,
    required this.report,
    required this.onOpen,
    this.width = 250,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final reports = (report['event_reports'] as List? ?? [report]).cast<Map>();
    final families = reports.fold<int>(
      0,
      (a, r) => a + ((r['affected_families'] as num?)?.toInt() ?? 0),
    );
    final open = reports.where((r) => _pct(r) < 100).length;
    return SizedBox(
      width: width,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DisasterArt(disasterKind(report['disaster']), height: 100),
              Padding(
                padding: const EdgeInsets.all(Space.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        PriorityChip(report['priority_level'] as String?),
                        const Spacer(),
                        Icon(
                          Icons.share_location_outlined,
                          size: 18,
                          color: cs.primary,
                        ),
                      ],
                    ),
                    Gaps.v8,
                    Text(
                      '${report['event_name'] ?? report['disaster']}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: t.titleMedium,
                    ),
                    Text(
                      '${barangaysText(reports.length)} · $families families',
                      style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                    Gaps.v8,
                    FulfillmentBar(
                      delivered: 0,
                      needed: 0,
                      percent: eventPercent(reports),
                    ),
                    Gaps.v8,
                    Text(
                      open == 0
                          ? 'Every barangay has what it needs'
                          : open == 1
                          ? '1 barangay still needs help'
                          : '$open barangays still need help',
                      style: t.bodySmall,
                    ),
                    Gaps.v8,
                    AppButton(
                      'Choose a barangay',
                      key: const ValueKey('choose-barangay'),
                      variant: AppButtonVariant.donate,
                      expand: true,
                      onPressed: onOpen,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The event page (GET /reports/events/{id}): every barangay of the event,
/// lowest progress first. Validated barangays under 100% have Donate; a
/// barangay still waiting for the Administrator shows "Awaiting validation"
/// with no details.
class EventScreen extends StatelessWidget {
  final int eventId;
  const EventScreen({super.key, required this.eventId});

  void _donate(BuildContext context, Map row, Names names) {
    final report = names
        .rows('validated_reports')
        .where((r) => '${r['id']}' == '${row['report_id']}')
        .firstOrNull;
    if (report == null) {
      AppToast.info(context, 'Pull down to refresh, then try again.');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DonateScreen(report: report, names: names),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Choose a barangay')),
      body: Loader(
        load: [() => api.get('/reports/events/$eventId'), api.lookupsResult],
        builder: (context, data) {
          final e = Map<String, dynamic>.from(data[0] as Map);
          final names = Names(Map<String, dynamic>.from(data[1] as Map));
          final rows = (e['reports'] as List).cast<Map>();
          final donatable = rows.where((r) => r['donatable'] == true).toList();
          final validated = rows.where((r) => r['status'] == 'Validated');
          return ListView(
            padding: Space.page,
            children: [
              _EventHeader(event: e),
              Gaps.v16,
              // Not sure where to give? The barangay with the least (rows
              // come lowest % first from the server).
              if (donatable.isNotEmpty)
                AppButton(
                  'Donate where it\'s needed most: ${donatable.first['barangay']}',
                  key: const ValueKey('donate-most-needed'),
                  icon: Icons.volunteer_activism_outlined,
                  variant: AppButtonVariant.donate,
                  large: true,
                  expand: true,
                  onPressed: () => _donate(context, donatable.first, names),
                )
              else if (validated.isNotEmpty)
                const AppCard(
                  child: EmptyView(
                    compact: true,
                    icon: Icons.verified_outlined,
                    title: 'Every barangay has what it needs',
                    message: 'Thank you to everyone who gave.',
                  ),
                ),
              Gaps.v16,
              const SectionHeader(
                'Or choose a barangay',
                subtitle:
                    'Least supplied first. Your donation goes to the '
                    'barangay you choose.',
              ),
              for (final r in rows) ...[
                _BarangayRow(
                  row: r,
                  onDonate: r['donatable'] == true
                      ? () => _donate(context, r, names)
                      : null,
                  // Logged-in users can open the whole report.
                  onDetails: api.loggedIn && r['report_id'] != null
                      ? () => showReportSheet(
                          context,
                          (r['report_id'] as num).toInt(),
                        )
                      : null,
                ),
                Gaps.v8,
              ],
            ],
          );
        },
      ),
    );
  }
}

class _EventHeader extends StatelessWidget {
  final Map<String, dynamic> event;
  const _EventHeader({required this.event});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final e = event;
    final awaiting = (e['awaiting_count'] as num?)?.toInt() ?? 0;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DisasterArt(disasterKind(e['disaster']), height: 140),
          Padding(
            padding: const EdgeInsets.all(Space.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (e['priority_level'] != null) ...[
                  PriorityChip('${e['priority_level']}'),
                  Gaps.v8,
                ],
                Text('${e['event_name']}', style: t.titleLarge),
                Gaps.v4,
                Text(
                  '${barangaysText((e['barangay_count'] as num?)?.toInt() ?? 0)} · '
                  '${e['total_families']} families'
                  '${awaiting > 0 ? ' · $awaiting awaiting validation' : ''}',
                  style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
                Gaps.v12,
                FulfillmentBar(
                  delivered: 0,
                  needed: 0,
                  percent: e['fulfillment_percentage'] as num?,
                  label: 'Event fulfilled',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BarangayRow extends StatelessWidget {
  final Map row;
  final VoidCallback? onDonate;
  final VoidCallback? onDetails;
  const _BarangayRow({
    required this.row,
    required this.onDonate,
    this.onDetails,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final r = row;
    final validated = r['status'] == 'Validated';
    final pct = _pct(r);
    final top = (r['top_needs'] as List? ?? const []).cast<Map>();
    final families = r['affected_families'];
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Barangay ${r['barangay']}', style: t.titleMedium),
                    if (families != null)
                      Text(
                        '$families families',
                        style: t.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              if (validated && r['priority_level'] != null)
                PriorityChip('${r['priority_level']}'),
            ],
          ),
          Gaps.v8,
          if (!validated)
            Row(
              children: [
                Icon(Icons.hourglass_top, size: 18, color: cs.onSurfaceVariant),
                Gaps.h8,
                Expanded(
                  child: Text(
                    r['status'] == 'Awaiting validation' ||
                            r['status'] == 'Pending'
                        ? 'Awaiting validation. Donations open once the '
                              'City validates it.'
                        : '${r['status']}',
                    style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            )
          else ...[
            FulfillmentBar(delivered: 0, needed: 0, percent: pct),
            if (top.isNotEmpty) ...[
              Gaps.v8,
              NeedChips([
                for (final n in top)
                  '${n['item_name']}: ${n['still_needed']} ${n['unit'] ?? ''}'
                      .trim(),
              ]),
            ],
            Gaps.v12,
            Row(
              children: [
                if (onDetails != null) ...[
                  OutlinedButton(
                    onPressed: onDetails,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                    ),
                    child: const Text('Details'),
                  ),
                  Gaps.h8,
                ],
                Expanded(
                  child: onDonate != null
                      ? AppButton(
                          'Donate to ${r['barangay']}',
                          key: ValueKey('donate-${r['report_id']}'),
                          variant: AppButtonVariant.donate,
                          icon: Icons.volunteer_activism_outlined,
                          expand: true,
                          onPressed: onDonate,
                        )
                      : const Align(
                          alignment: Alignment.centerLeft,
                          child: StatusChip('Fulfilled'),
                        ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
