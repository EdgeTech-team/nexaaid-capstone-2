import 'dart:convert';

import 'package:flutter/material.dart';

import '../api.dart' show ApiResult;
import 'donation_entries_view.dart';
import 'donor_dashboard.dart'
    show DonationDetailScreen, ReportProgressCard, donationStep;
import 'home_nav.dart';
import 'item_art.dart';
import 'widgets.dart';

// ---------------------------------------------------------------------------
// Ivan (simple donor screens): the donor / relief organization's Reports
// tab is about their own giving (UC-D3 / UC-R3, section 7.3):
//   1. four cards, each opens its list,
//   2. donation status, the whole journey on each donation (Pledged ->
//      Received by CSWS -> Acknowledged by CMO -> In transit -> Delivered ->
//      Barangay confirmed), with "Show QR" while it still waits.
// Oct 13: there is no separate delivery list any more. Each delivery
// records whose goods it took (first received, first sent), so the
// donation's own timeline moves (GET /donations/mine "lifecycle_status",
// "delivery_note").
// ---------------------------------------------------------------------------

const _donationSteps = ['Pending', 'Received', 'Confirmed'];
const _donationLabels = ['Pledged', 'Received by CSWS', 'Acknowledged by CMO'];

/// Oct 12 (team): each donation entry shows its full journey again, as on
/// develop: Pledged -> Received by CSWS -> Acknowledged by CMO -> In
/// transit -> Delivered -> Barangay confirmed (design/status.dart), and
/// "Show QR" while it still waits for drop-off or pickup.
/// donationLifecycleLabels with line breaks, so six steps fit a phone.
const _journeyLabels = [
  'Pledged',
  'Received\nby CSWS',
  'Acknowledged\nby CMO',
  'In transit',
  'Delivered',
  'Barangay\nconfirmed',
];

Widget entryJourney(BuildContext context, Map e) {
  final status = '${e['status'] ?? 'Pending'}';
  final closed = status == 'Expired' || status == 'Cancelled';
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (!closed)
        StatusTimeline(
          steps: donationLifecycle,
          labels: _journeyLabels,
          current: donationStep(e),
        ),
      // Oct 13: part of the goods already left; the step moves when all do.
      if (!closed && e['delivery_note'] != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            children: [
              const Icon(Icons.local_shipping_outlined, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${e['delivery_note']}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      if (isWaiting(e) && !closed)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => showDonationQr(context, '${e['batch_reference']}'),
            icon: const Icon(Icons.qr_code_2),
            label: const Text('Show QR'),
          ),
        ),
    ],
  );
}

/// Short status words a donor understands.
String donationStatusLabel(Object? status) => switch ('$status') {
  'Pending' => 'Waiting',
  'Partly Received' => 'Partly received',
  'Received' => 'Received by CSWS',
  'Confirmed' => 'Acknowledged by CMO',
  final s => s,
};

/// Still has goods waiting for drop-off or pickup.
bool isWaiting(Map e) => ((e['pending_items'] as num?) ?? 0) > 0;

/// Oct 13: goods of this donation are on the road (all of them in
/// transit, or part of them already sent).
bool isOnTheWay(Map e) =>
    e['lifecycle_status'] == 'In Transit' || e['delivery_note'] != null;

/// "See all reports" / "Find a barangay to help": the Reports tab (every
/// validated report with its filters), not a second copy of it.
void openAllReports(BuildContext context) =>
    HomeNav.go(context, const HomeTarget('Reports'));

class MyGivingScreen extends StatefulWidget {
  const MyGivingScreen({super.key});

  @override
  State<MyGivingScreen> createState() => _MyGivingScreenState();
}

class _MyGivingScreenState extends State<MyGivingScreen> {
  int _loads = 0; // a new value reloads (after an edit or delete)

  Future<void> _push(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    if (mounted) setState(() => _loads++);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Loader(
      key: ValueKey(_loads),
      load: [() => api.get('/donations/mine')],
      builder: (context, data) {
        final m = data[0] as Map;
        final entries = (m['entries'] as List? ?? const []).cast<Map>();
        final supported = (m['supported_reports'] as List? ?? const [])
            .cast<Map>();
        final waiting = entries.where(isWaiting).toList();
        final moving = entries.where(isOnTheWay).toList();

        return ListView(
          physics: const AlwaysScrollableScrollPhysics(), // pull to refresh
          padding: Space.page,
          children: [
            Text('My giving', style: t.headlineSmall),
            Gaps.v4,
            Text(
              entries.isEmpty
                  ? 'Your donations and their deliveries will show here.'
                  : 'Tap a card to see the list.',
              style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            Gaps.v16,
            if (entries.isEmpty)
              AppCard(
                child: EmptyView(
                  compact: true,
                  icon: Icons.volunteer_activism_outlined,
                  title: 'You haven\'t donated yet',
                  message:
                      'Pick a barangay that needs help and pledge goods. '
                      'You can follow them all the way to the barangay.',
                  action: AppButton(
                    'Find a barangay to help',
                    icon: Icons.search,
                    variant: AppButtonVariant.donate,
                    onPressed: () => openAllReports(context),
                  ),
                ),
              )
            else ...[
              // ---- 1. Four cards, each opens its list -----------------
              StatCardGrid([
                StatCard(
                  label: 'Donations made',
                  value: '${entries.length}',
                  icon: Icons.volunteer_activism_outlined,
                  onTap: () => _push(const MyDonationsScreen()),
                ),
                StatCard(
                  label: 'Waiting for drop-off or pickup',
                  value: '${waiting.length}',
                  icon: Icons.schedule,
                  color: StatusColors.base('Pending'),
                  onTap: () =>
                      _push(const MyDonationsScreen(waitingOnly: true)),
                ),
                StatCard(
                  label: 'In delivery',
                  value: '${moving.length}',
                  icon: Icons.local_shipping_outlined,
                  color: StatusColors.base('In Transit'),
                  onTap: () =>
                      _push(const MyDonationsScreen(onTheWayOnly: true)),
                ),
                StatCard(
                  label: 'Reports supported',
                  value: '${supported.length}',
                  icon: Icons.campaign_outlined,
                  color: StatusColors.base('Confirmed'),
                  onTap: () =>
                      _push(SupportedReportsScreen(reports: supported)),
                ),
              ]),

              // ---- 2. Donation status ---------------------------------
              const SectionHeader(
                'Donation status',
                subtitle: 'Each donation and where it is now.',
              ),
              // Every entry (one QR each) with the status chips, search,
              // report and handover filters and the sort, as on develop.
              // 9.4 (testing): more room between donations.
              DonationEntriesView(
                entries: entries,
                gap: Space.lg,
                footer: (e) => entryJourney(context, e),
                onTap: (e) => _push(DonationDetailScreen(entry: e)),
              ),
              Gaps.v8,
            ],
          ],
        );
      },
    );
  }
}

/// One donation: item picture, items, its report, a 3-step status line,
/// and "Show QR" while it still waits for drop-off or pickup.
class DonationStatusCard extends StatelessWidget {
  final Map entry;
  final VoidCallback onTap;
  const DonationStatusCard({
    super.key,
    required this.entry,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final e = entry;
    final items = (e['items'] as List? ?? const []).cast<Map>();
    final status = '${e['status'] ?? 'Pending'}';
    final closed = status == 'Expired' || status == 'Cancelled';
    return AppCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ItemArt(items.isEmpty ? null : items.first['item_name']),
              Gaps.h12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      itemsSummary(e),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: t.titleSmall,
                    ),
                    Gaps.v4,
                    Text(
                      'For ${entryReportLabel(e)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Gaps.h8,
              StatusChip(status, label: donationStatusLabel(status)),
            ],
          ),
          if (!closed) ...[
            Gaps.v12,
            StatusTimeline(
              steps: _donationSteps,
              labels: _donationLabels,
              current: donationStep(e),
            ),
          ],
          if (isWaiting(e) && !closed) ...[
            Gaps.v8,
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () =>
                    showDonationQr(context, '${e['batch_reference']}'),
                icon: const Icon(Icons.qr_code_2),
                label: const Text('Show QR'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The donation's QR, to show at the CSWS office or to the pickup team.
Future<void> showDonationQr(BuildContext context, String reference) =>
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Your donation QR'),
        content: SizedBox(
          width: 260,
          child: FutureBuilder<ApiResult>(
            future: api.get('/donations/batch/$reference/qr'),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: Skeleton(width: 220, height: 220));
              }
              final r = snap.data!;
              final b64 = r.ok && r.json is Map
                  ? (r.json as Map)['qr_image_base64'] as String?
                  : null;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (b64 == null)
                    Text(
                      'The QR code couldn\'t load. Your reference is '
                      '$reference.',
                    )
                  else
                    Semantics(
                      label: 'QR code for $reference',
                      child: Container(
                        padding: const EdgeInsets.all(Space.sm),
                        color: Colors.white, // QR needs a white background
                        child: Image.memory(
                          base64Decode(b64),
                          width: 220,
                          height: 220,
                        ),
                      ),
                    ),
                  Gaps.v12,
                  Text(
                    reference,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  Gaps.v4,
                  Text(
                    'Show this at the CSWS Main Office, or to the team that '
                    'picks up your donation.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              );
            },
          ),
        ),
        actions: [
          AppButton(
            'Close',
            variant: AppButtonVariant.text,
            onPressed: () => Navigator.of(ctx).pop(),
          ),
        ],
      ),
    );

// ---------------------------------------------------------------------------
// The pages behind the four cards.
// ---------------------------------------------------------------------------

/// Every donation entry with filters, QR and timeline (UC-D3 / UC-R3,
/// Appendix H 4.4 / 4.5). [waitingOnly]: only the ones still waiting for
/// drop-off or pickup. Edits and deletes reload it.
class MyDonationsScreen extends StatefulWidget {
  final bool waitingOnly;

  /// Oct 13: only donations whose goods are on the road.
  final bool onTheWayOnly;
  const MyDonationsScreen({
    super.key,
    this.waitingOnly = false,
    this.onTheWayOnly = false,
  });

  @override
  State<MyDonationsScreen> createState() => _MyDonationsScreenState();
}

class _MyDonationsScreenState extends State<MyDonationsScreen> {
  int _loads = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.waitingOnly
              ? 'Waiting for drop-off or pickup'
              : widget.onTheWayOnly
              ? 'In delivery'
              : 'My donations',
        ),
      ),
      body: Loader(
        key: ValueKey(_loads),
        load: [() => api.get('/donations/mine')],
        builder: (context, data) {
          final all = ((data[0] as Map)['entries'] as List).cast<Map>();
          final entries = widget.waitingOnly
              ? all.where(isWaiting).toList()
              : widget.onTheWayOnly
              ? all.where(isOnTheWay).toList()
              : all;
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: Space.page,
            children: [
              DonationEntriesView(
                entries: entries,
                emptyTitle: widget.waitingOnly
                    ? 'Nothing is waiting'
                    : widget.onTheWayOnly
                    ? 'Nothing is on the road'
                    : 'You haven\'t donated yet',
                emptyMessage: widget.waitingOnly
                    ? 'Every donation has been dropped off or picked up.'
                    : widget.onTheWayOnly
                    ? 'When CSWS sends your goods to the barangay, they show here.'
                    : 'Pick a barangay that needs help and pledge goods.',
                gap: Space.lg,
                footer: (e) => entryJourney(context, e),
                onTap: (e) async {
                  final changed = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) => DonationDetailScreen(entry: e),
                    ),
                  );
                  if (changed == true && mounted) setState(() => _loads++);
                },
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The reports this user donated to, with their progress.
class SupportedReportsScreen extends StatelessWidget {
  final List<Map> reports;
  const SupportedReportsScreen({super.key, required this.reports});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reports I supported')),
      body: ListView(
        padding: Space.page,
        children: [
          if (reports.isEmpty)
            const AppCard(
              child: EmptyView(
                compact: true,
                icon: Icons.campaign_outlined,
                title: 'No reports supported yet',
                message:
                    'When you donate to a report, its progress shows here.',
              ),
            ),
          for (final r in reports) ...[ReportProgressCard(report: r), Gaps.v12],
        ],
      ),
    );
  }
}
