import 'dart:convert';

import 'package:flutter/material.dart';

import '../api.dart' show ApiResult;
import 'donation_entries_view.dart';
import 'donor_dashboard.dart'
    show DonationDetailScreen, ReportProgressCard, donationStep;
import 'donor_screens.dart' show DonorReportsTab;
import 'item_art.dart';
import 'widgets.dart';

// ---------------------------------------------------------------------------
// Ivan (simple donor screens): the donor / relief organization's Reports
// tab is about their own giving (UC-D3 / UC-R3, section 7.3):
//   1. four cards, each opens its list,
//   2. donation status (Pledged -> Received by CSWS -> Acknowledged by CMO),
//      with "Show QR" on donations still waiting for drop-off or pickup,
//   3. delivery status (In transit -> Delivered -> Barangay confirmed).
// Donated goods go into CSWS inventory and are delivered per report, so the
// deliveries shown are the ones going to the reports this user donated to
// (GET /donations/mine "deliveries").
// ---------------------------------------------------------------------------

const _donationSteps = ['Pending', 'Received', 'Confirmed'];
const _donationLabels = ['Pledged', 'Received by CSWS', 'Acknowledged by CMO'];
const _deliverySteps = ['In Transit', 'Delivered', 'Confirmed'];
const _deliveryLabels = ['In transit', 'Delivered', 'Barangay confirmed'];

/// Short status words a donor understands.
String donationStatusLabel(Object? status) => switch ('$status') {
  'Pending' => 'Waiting',
  'Partly Received' => 'Partly received',
  'Received' => 'Received by CSWS',
  'Confirmed' => 'Acknowledged by CMO',
  final s => s,
};

String deliveryStatusLabel(Object? status) => switch ('$status') {
  'Preparing' => 'Being prepared',
  'In Transit' => 'In transit',
  'Delivered' => 'Delivered',
  'Confirmed' => 'Barangay confirmed',
  final s => s,
};

/// Still has goods waiting for drop-off or pickup.
bool isWaiting(Map e) => ((e['pending_items'] as num?) ?? 0) > 0;

/// On its way: being prepared or in transit.
bool isInDelivery(Map d) =>
    d['status'] == 'Preparing' || d['status'] == 'In Transit';

/// The page behind "See all reports" / "Find a barangay to help".
void openAllReports(BuildContext context) => Navigator.of(context).push(
  MaterialPageRoute(
    builder: (_) => Scaffold(
      appBar: AppBar(title: const Text('All reports')),
      body: const DonorReportsTab(),
    ),
  ),
);

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
        final deliveries = (m['deliveries'] as List? ?? const []).cast<Map>();
        final waiting = entries.where(isWaiting).toList();
        final moving = deliveries.where(isInDelivery).toList();

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
                  onTap: () => _push(const MyDonationsScreen(waitingOnly: true)),
                ),
                StatCard(
                  label: 'In delivery',
                  value: '${moving.length}',
                  icon: Icons.local_shipping_outlined,
                  color: StatusColors.base('In Transit'),
                  onTap: () => _push(
                    MyDeliveriesScreen(deliveries: moving, activeOnly: true),
                  ),
                ),
                StatCard(
                  label: 'Reports supported',
                  value: '${supported.length}',
                  icon: Icons.campaign_outlined,
                  color: StatusColors.base('Confirmed'),
                  onTap: () => _push(SupportedReportsScreen(reports: supported)),
                ),
              ]),

              // ---- 2. Donation status ---------------------------------
              SectionHeader(
                'Donation status',
                action: entries.length > 3
                    ? TextButton(
                        onPressed: () => _push(const MyDonationsScreen()),
                        child: Text('See all ${entries.length}'),
                      )
                    : null,
              ),
              for (final e in entries.take(3)) ...[
                DonationStatusCard(
                  entry: e,
                  onTap: () => _push(DonationDetailScreen(entry: e)),
                ),
                Gaps.v8,
              ],

              // ---- 3. Delivery status ---------------------------------
              SectionHeader(
                'Delivery status',
                subtitle: 'Deliveries to the barangays you donated to.',
                action: deliveries.length > 3
                    ? TextButton(
                        onPressed: () =>
                            _push(MyDeliveriesScreen(deliveries: deliveries)),
                        child: Text('See all ${deliveries.length}'),
                      )
                    : null,
              ),
              if (deliveries.isEmpty)
                const AppCard(
                  child: EmptyView(
                    compact: true,
                    icon: Icons.local_shipping_outlined,
                    title: 'No deliveries yet',
                    message:
                        'When CSWS sends goods to a barangay you donated to, '
                        'you will see it here.',
                  ),
                ),
              for (final d in deliveries.take(3)) ...[
                DeliveryStatusCard(delivery: d),
                Gaps.v8,
              ],
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

/// One delivery to a report this user donated to.
class DeliveryStatusCard extends StatelessWidget {
  final Map delivery;
  const DeliveryStatusCard({super.key, required this.delivery});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final d = delivery;
    final status = '${d['status']}';
    final when = d['confirmed_at'] ?? d['delivery_date'];
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: StatusColors.of(
                  status,
                  Theme.of(context).brightness,
                ).bg,
                child: Icon(
                  Icons.local_shipping_outlined,
                  color: StatusColors.of(
                    status,
                    Theme.of(context).brightness,
                  ).fg,
                ),
              ),
              Gaps.h12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${d['items_summary'] ?? 'Relief goods'} to Barangay '
                      '${d['barangay'] ?? '-'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: t.titleSmall,
                    ),
                    Gaps.v4,
                    Text(
                      [
                        if (d['report_label'] != null) '${d['report_label']}',
                        if (when != null) niceDate(when),
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Gaps.h8,
              StatusChip(status, label: deliveryStatusLabel(status)),
            ],
          ),
          Gaps.v12,
          StatusTimeline(
            steps: _deliverySteps,
            labels: _deliveryLabels,
            current: status,
          ),
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
                    Text('The QR code couldn\'t load. Your reference is '
                        '$reference.')
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
  const MyDonationsScreen({super.key, this.waitingOnly = false});

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
          widget.waitingOnly ? 'Waiting for drop-off or pickup' : 'My donations',
        ),
      ),
      body: Loader(
        key: ValueKey(_loads),
        load: [() => api.get('/donations/mine')],
        builder: (context, data) {
          final all = ((data[0] as Map)['entries'] as List).cast<Map>();
          final entries = widget.waitingOnly
              ? all.where(isWaiting).toList()
              : all;
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: Space.page,
            children: [
              DonationEntriesView(
                entries: entries,
                emptyTitle: widget.waitingOnly
                    ? 'Nothing is waiting'
                    : 'You haven\'t donated yet',
                emptyMessage: widget.waitingOnly
                    ? 'Every donation has been dropped off or picked up.'
                    : 'Pick a barangay that needs help and pledge goods.',
                footer: (e) => StatusTimeline(
                  steps: _donationSteps,
                  labels: _donationLabels,
                  current: donationStep(e),
                ),
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

/// Deliveries to the reports this user donated to.
class MyDeliveriesScreen extends StatelessWidget {
  final List<Map> deliveries;
  final bool activeOnly;
  const MyDeliveriesScreen({
    super.key,
    required this.deliveries,
    this.activeOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(activeOnly ? 'In delivery' : 'Delivery status'),
      ),
      body: ListView(
        padding: Space.page,
        children: [
          if (deliveries.isEmpty)
            AppCard(
              child: EmptyView(
                compact: true,
                icon: Icons.local_shipping_outlined,
                title: activeOnly
                    ? 'Nothing is on the way right now'
                    : 'No deliveries yet',
                message:
                    'When CSWS sends goods to a barangay you donated to, you '
                    'will see it here.',
              ),
            ),
          for (final d in deliveries) ...[
            DeliveryStatusCard(delivery: d),
            Gaps.v8,
          ],
        ],
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
          for (final r in reports) ...[
            ReportProgressCard(report: r),
            Gaps.v12,
          ],
        ],
      ),
    );
  }
}
