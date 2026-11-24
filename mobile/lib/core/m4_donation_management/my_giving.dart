import 'dart:convert';

import 'package:flutter/material.dart';

import '../shared/api.dart' show ApiResult;
import 'donation_entries_view.dart';
import '../m9_dashboards/donor_dashboard.dart'
    show DonationDetailScreen, ReportProgressCard, donationStep;
import '../shared/home_nav.dart';
import '../shared/item_art.dart';
import 'paged_donation_entries.dart';
import '../shared/widgets.dart';

// ---------------------------------------------------------------------------
// Ivan (simple donor screens): the donor / relief organization's Reports
// tab is about their own giving (UC-D3 / UC-R3, section 7.3):
//   1. four cards, each opens its list,
//   2. donation status, the whole journey on each donation (Pledged ->
//      Received by CSWS -> In transit -> Delivered -> Barangay confirmed),
//      with "Show QR" while it still waits. Oct 25: no "Acknowledged by
//      CMO" step for donors; an acknowledged donation reads as received.
// Oct 13: there is no separate delivery list any more. Each delivery
// records whose goods it took (first received, first sent), so the
// donation's own timeline moves (GET /donations/mine "lifecycle_status",
// "delivery_note").
// ---------------------------------------------------------------------------

const _donationSteps = ['Pending', 'Received'];
const _donationLabels = ['Pledged', 'Received by CSWS'];

/// Oct 12 (team): each donation entry shows its full journey again, as on
/// develop: Pledged -> Received by CSWS -> In transit -> Delivered ->
/// Barangay confirmed (core/shared/design/status.dart), and "Show QR" while it still
/// waits for drop-off or pickup.
/// donationLifecycleLabels with line breaks, so the steps fit a phone.
const _journeyLabels = [
  'Pledged',
  'Received\nby CSWS',
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
  'Confirmed' => 'Received by CSWS', // the CMO step is not shown to donors
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
  // Edits and deletes reload the counts and the list by themselves (Api
  // notifies after a change).
  Future<void> _push(Widget page) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    // NF-003: the four cards' numbers come from the server; the donations
    // below are 10 per page (GET /donations/mine/entries).
    return Loader(
      load: [() => api.get('/donations/mine/entries/counts')],
      builder: (context, data) {
        final c = data[0] is Map ? data[0] as Map : const {};
        final summary = (c['summary'] as Map?) ?? const {};
        final supported = ((c['supported_reports'] as List?) ?? const [])
            .cast<Map>();
        final all = (c['all'] as num?)?.toInt() ?? 0;
        final title = [
          Text('My giving', style: t.headlineSmall),
          if (all == 0) ...[
            Gaps.v4,
            Text(
              'Your donations and their deliveries will show here.',
              style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
          Gaps.v16,
        ];
        if (all == 0) {
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(), // pull to refresh
            padding: Space.page,
            children: [
              ...title,
              AppCard(
                child: EmptyView(
                  compact: true,
                  icon: Icons.volunteer_activism_outlined,
                  title: "You haven't donated yet",
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
              ),
            ],
          );
        }
        return PagedDonationEntries(
          donor: true,
          // 9.4 (testing): more room between donations.
          gap: Space.lg,
          header: [
            ...title,
            // ---- 1. Four cards, each opens its list -------------------
            StatCardGrid([
              StatCard(
                label: 'Donations made',
                value: '${summary['entries'] ?? all}',
                icon: Icons.volunteer_activism_outlined,
                onTap: () => _push(const MyDonationsScreen()),
              ),
              StatCard(
                label: 'Waiting for drop-off or pickup',
                value: '${summary['waiting'] ?? 0}',
                icon: Icons.schedule,
                color: StatusColors.base('Pending'),
                onTap: () => _push(const MyDonationsScreen(waitingOnly: true)),
              ),
              StatCard(
                label: 'In delivery',
                value: '${summary['on_the_way'] ?? 0}',
                icon: Icons.local_shipping_outlined,
                color: StatusColors.base('In Transit'),
                onTap: () => _push(const MyDonationsScreen(onTheWayOnly: true)),
              ),
              StatCard(
                label: 'Reports supported',
                value: '${supported.length}',
                icon: Icons.campaign_outlined,
                color: StatusColors.base('Confirmed'),
                onTap: () => _push(SupportedReportsScreen(reports: supported)),
              ),
            ]),
            // ---- 2. Donation status -----------------------------------
            const SectionHeader(
              'Donation status',
              subtitle: 'Each donation and where it is now.',
            ),
          ],
          footer: (e) => entryJourney(context, e),
          onTap: (e) => _push(DonationDetailScreen(entry: e)),
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
      // NF-003: 20 donations per page, filtered on the server. Edits and
      // deletes reload the page by themselves.
      body: PagedDonationEntries(
        donor: true,
        donorView: widget.waitingOnly
            ? 'waiting'
            : widget.onTheWayOnly
            ? 'on_the_way'
            : null,
        emptyTitle: widget.waitingOnly
            ? 'Nothing is waiting'
            : widget.onTheWayOnly
            ? 'Nothing is on the road'
            : "You haven't donated yet",
        emptyMessage: widget.waitingOnly
            ? 'Every donation has been dropped off or picked up.'
            : widget.onTheWayOnly
            ? 'When CSWS sends your goods to the barangay, they show here.'
            : 'Pick a barangay that needs help and pledge goods.',
        gap: Space.lg,
        footer: (e) => entryJourney(context, e),
        onTap: (e) => Navigator.of(context).push<bool>(
          MaterialPageRoute(builder: (_) => DonationDetailScreen(entry: e)),
        ),
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
