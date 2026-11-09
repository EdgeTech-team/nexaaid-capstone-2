import 'package:flutter/material.dart';

import 'disaster_art.dart';
import 'donor_screens.dart' show DonateScreen;
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

/// Opens the event page.
void openEvent(BuildContext context, Map report, Names names) =>
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EventScreen(
          eventId: (report['event_id'] as num).toInt(),
          names: names,
        ),
      ),
    );

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
                      '${reports.length} barangays · $families families',
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
                      open == 1
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
  final Names names;
  const EventScreen({super.key, required this.eventId, required this.names});

  void _donate(BuildContext context, Map row) {
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
        load: [() => api.get('/reports/events/$eventId')],
        builder: (context, data) {
          final e = Map<String, dynamic>.from(data[0] as Map);
          final rows = (e['reports'] as List).cast<Map>();
          return ListView(
            padding: Space.page,
            children: [
              _EventHeader(event: e),
              Gaps.v16,
              SectionHeader(
                'Barangays',
                subtitle:
                    'Least supplied first. Your donation goes to the '
                    'barangay you choose.',
              ),
              for (final r in rows) ...[
                _BarangayRow(
                  row: r,
                  onDonate: r['donatable'] == true
                      ? () => _donate(context, r)
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
                  '${e['barangay_count']} barangays · '
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
  const _BarangayRow({required this.row, required this.onDonate});

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
            if (onDonate != null)
              AppButton(
                'Donate to ${r['barangay']}',
                key: ValueKey('donate-${r['report_id']}'),
                variant: AppButtonVariant.donate,
                icon: Icons.volunteer_activism_outlined,
                expand: true,
                onPressed: onDonate,
              )
            else
              const Align(
                alignment: Alignment.centerLeft,
                child: StatusChip('Fulfilled'),
              ),
          ],
        ],
      ),
    );
  }
}
