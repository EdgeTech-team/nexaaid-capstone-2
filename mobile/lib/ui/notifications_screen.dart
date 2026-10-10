import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../report_detail_screen.dart';
import '../report_model.dart';
import 'admin_screens.dart';
import 'batch_sheet.dart' show openDonationByQr;
import 'donor_dashboard.dart';
import 'ops_screens.dart';
import 'widgets.dart';

/// Where each notification type opens. Every module owner adds their own entry
/// when their detail screen exists, e.g.:
///
///   'donation_batch': (c, id) => Navigator.of(c).push(
///       MaterialPageRoute(builder: (_) => DonationBatchScreen(batchId: id))),
///
/// Unknown entity types simply mark the notification read and stay on the inbox.
typedef EntityOpener = void Function(BuildContext context, int entityId);

/// Tab-body screens have no Scaffold of their own, so wrap them to get an app
/// bar and a back button when they are pushed from the inbox.
Widget _withAppBar(String title, Widget body) => Scaffold(
  appBar: AppBar(title: Text(title)),
  body: body,
);

void _push(BuildContext c, Widget screen) {
  Navigator.of(c).push(MaterialPageRoute(builder: (_) => screen));
}

final Map<String, EntityOpener> notificationDestinations = {
  // Concerns2.txt 2.1: every report notification (submitted, validated,
  // open for donations, rejected) opens a clear pop-up summary of the
  // report. "See full details" inside it opens ReportDetailScreen.
  'report': (c, id) => showReportSheet(c, id),
  // Donation notifications open the right screen for each role:
  //   CSWS Main Office / Administrator: that donation's details sheet
  //     (items, donor, deadline, Receive / Reopen / Cancel buttons)
  //   CMO: the confirmations list
  //   Donor / Relief Organization: their own donations
  'donation': (c, id) => _openDonation(c, id),
  // delivery_status_changed goes to the barangay representative and the
  // reporter; delivery_receipt_confirmed goes to CSWS Main Office and the
  // reporter. Only the barangay representative and CSWS Main Office have a
  // deliveries screen in the app. Every other role (the Administrator, or a
  // donor or CSWS Disaster Unit user who filed the report) stays on the
  // inbox, since the Administrator has no deliveries tab to land on and the
  // reporter would get a 403 from the delivery routes.
  'delivery': (c, id) {
    final Widget? screen;
    switch (api.role) {
      case Roles.barangay:
        screen = _withAppBar(
          'Incoming aid',
          const DeliveriesScreen(barangay: true),
        );
        break;
      case Roles.cswsMain:
        screen = _withAppBar('Deliveries', const DeliveriesScreen());
        break;

      case Roles.drrmo:
        screen = _withAppBar('Logistics requests', const DrrmoScreen());
        break;
      default:
        screen = null;
    }
    if (screen != null) _push(c, screen);
  },

  // logistics_requested goes to DRRMO; logistics_scheduled and
  // logistics_declined go back to the CSWS Main Office user who asked.
  'logistics_request': (c, id) {
    final Widget? screen;
    switch (api.role) {
      case Roles.drrmo:
        screen = _withAppBar('Logistics requests', const DrrmoScreen());
        break;
      case Roles.cswsMain:
        screen = _withAppBar('Deliveries', const DeliveriesScreen());
        break;
      default:
        screen = null;
    }
    if (screen != null) _push(c, screen);
  },
  // org_registered goes to every Administrator. org_approved and org_rejected
  // go to the organization's own account, which has no screen for this, so it
  // stays on the inbox.
  'organization': (c, id) {
    if (api.role == Roles.admin) {
      _push(c, _withAppBar('Organizations', const OrganizationsReview()));
    }
  },
  // 'donation_batch': (c, id) => ...,
};

Future<void> _openDonation(BuildContext c, int donationId) async {
  switch (api.role) {
    case Roles.cswsMain:
    case Roles.admin:
      // The notification points at one item; its QR reference opens the
      // whole donation entry.
      final r = await api.get('/donations/$donationId/qr');
      if (!c.mounted) return;
      if (!r.ok || r.json is! Map) {
        ScaffoldMessenger.of(c).showSnackBar(
          const SnackBar(content: Text('This donation could not be found.')),
        );
        return;
      }
      await openDonationByQr(c, '${(r.json as Map)['batch_reference']}');
    case Roles.cmo:
      _push(c, _withAppBar('Confirmations', const CmoScreen()));
    case Roles.donor:
    case Roles.org:
      // DonorDashboard is a tab body (no Scaffold), so wrap it to get an
      // app bar and a back button.
      _push(c, _withAppBar('My donations', const DonorDashboard()));
    default:
      break; // other roles have no donation screen: stay on the inbox
  }
}

// ---------------------------------------------------------------------------
// Concerns2.txt 2.1: report pop-up for non-technical users.
// Loads GET /reports/{id} (report + fulfillment progress) and shows it in
// plain words. Every failure shows a message instead of failing silently.
// ---------------------------------------------------------------------------
Future<void> showReportSheet(BuildContext c, int id) async {
  final messenger = ScaffoldMessenger.of(c);
  messenger.showSnackBar(
    const SnackBar(
      content: Text('Opening report…'),
      duration: Duration(seconds: 1),
    ),
  );
  final r = await api.get('/reports/$id');
  if (!c.mounted) return;
  if (!r.ok || r.json is! Map) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          r.status == 403
              ? 'Report #$id is not open to you yet. '
                    'It may still be waiting for approval.'
              : r.status == 404
              ? 'Report #$id no longer exists.'
              : 'Could not open report #$id. '
                    'Check your connection and try again.',
        ),
      ),
    );
    return;
  }
  final report = Map<String, dynamic>.from(r.json as Map);

  // Names for the sitio (the report only carries its id). If this fails the
  // pop-up still opens, just without the sitio name.
  Names? names;
  try {
    names = Names(await api.lookups());
  } catch (e) {
    debugPrint('Report pop-up: lookups failed: $e');
  }
  if (!c.mounted) return;

  messenger.hideCurrentSnackBar();
  await showModalBottomSheet<void>(
    context: c,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => ReportSheet(report: report, names: names),
  );
}

class ReportSheet extends StatelessWidget {
  final Map<String, dynamic> report;
  final Names? names;
  const ReportSheet({super.key, required this.report, this.names});

  static String statusInWords(String? s) => switch (s) {
    'Pending' => 'Waiting for the Administrator to approve it',
    'Validated' => 'Approved. Donors can now send help.',
    'Rejected' => 'Sent back for corrections',
    _ => s ?? 'Unknown',
  };

  static IconData statusIcon(String? s) => switch (s) {
    'Validated' => Icons.verified_outlined,
    'Rejected' => Icons.error_outline,
    _ => Icons.hourglass_top,
  };

  static String priorityInWords(String? p) => switch (p) {
    'Critical' => 'Critical: needs help immediately',
    'High' => 'High: needs help soon',
    'Medium' => 'Medium: needs help, less urgent',
    'Low' => 'Low: least urgent',
    _ => 'Not rated yet',
  };

  /// "Rice: 50 kg, Drinking Water: 20 gallons" -> one line per need.
  static List<String> needsList(String? s) => (s ?? '')
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  String get _type =>
      '${report['disaster_type_name'] ?? names?.of('disaster_types', report['disaster_type_id']) ?? 'Disaster'}';

  String get _barangay =>
      '${report['barangay_name'] ?? names?.of('barangays', report['barangay_id']) ?? 'Unknown barangay'}';

  String get _sitio {
    final id = report['sitio_id'];
    if (id == null) return 'Whole barangay';
    final name = names?.of('sitios', id, fallback: '') ?? '';
    return name.isEmpty ? 'One sitio of the barangay' : 'Sitio $name';
  }

  void _openFullDetails(BuildContext context) {
    try {
      final full = Report.fromJson(report);
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ReportDetailScreen(report: full)),
      );
    } catch (e) {
      debugPrint('Open full report failed: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Full details are not available.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final status = report['status'] as String?;
    final needs = needsList(report['assistance_needed'] as String?);
    final families = report['affected_families'];
    final description = '${report['description'] ?? ''}'.trim();
    final hasProgress = report['total_items_needed'] != null;
    final delivered = (report['total_items_delivered'] as num?) ?? 0;
    final needed = (report['total_items_needed'] as num?) ?? 0;
    // Appendix H 3.2: every role except DRRMO views priority guidance.
    final showPriority = api.role != Roles.drrmo && status == 'Validated';
    final guidance = report['priority_guidance'] ?? report['ai_recommendation'];
    final reason = report['rejection_reason'];

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Headline: what and where, in large text.
          Text(
            '$_type in $_barangay',
            style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            'Report #${report['report_id']} · reported ${niceDate(report['created_at'])}',
            style: t.bodyMedium?.copyWith(color: Brand.muted),
          ),
          const SizedBox(height: 16),

          // Status in plain words.
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: Icon(statusIcon(status), size: 32),
              title: Text(
                statusInWords(status),
                style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ),

          _Section(
            label: 'Where',
            child: Text('$_barangay · $_sitio', style: t.titleMedium),
          ),

          if (families != null)
            _Section(
              label: 'Families affected',
              child: Text(
                '$families ${families == 1 ? 'family' : 'families'}',
                style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),

          if (needs.isNotEmpty)
            _Section(
              label: 'What they need',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final n in needs)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.check_circle_outline, size: 22),
                          const SizedBox(width: 8),
                          Expanded(child: Text(n, style: t.titleMedium)),
                        ],
                      ),
                    ),
                ],
              ),
            ),

          if (description.isNotEmpty)
            _Section(
              label: 'What happened',
              child: Text(description, style: t.bodyLarge),
            ),

          if (hasProgress)
            _Section(
              label: 'Help delivered so far',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Progress(
                    delivered: delivered,
                    needed: needed,
                    percent: num.tryParse(
                      '${report['fulfillment_percentage']}',
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$delivered of $needed items delivered',
                    style: t.bodyLarge,
                  ),
                ],
              ),
            ),

          if (showPriority)
            _Section(
              label: 'How urgent',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    priorityInWords(report['priority_level'] as String?),
                    style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  if (guidance != null) ...[
                    const SizedBox(height: 4),
                    Text('$guidance', style: t.bodyMedium),
                  ],
                ],
              ),
            ),

          if (status == 'Rejected' && reason != null)
            _Section(
              label: 'Why it was sent back',
              child: Text(
                '$reason',
                style: t.bodyLarge?.copyWith(color: const Color(0xFFC62828)),
              ),
            ),

          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
            ),
            child: const Text('Close'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => _openFullDetails(context),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
            ),
            child: const Text('See full details'),
          ),
        ],
      ),
    );
  }
}

/// A small grey label above a block of content.
class _Section extends StatelessWidget {
  final String label;
  final Widget child;
  const _Section({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Brand.muted,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }
}

/// Bell icon with an unread badge. Refreshes every 30 s, after any action
/// in the app (api notifies listeners), and when the inbox is closed.
class NotificationBell extends StatefulWidget {
  const NotificationBell({super.key});

  @override
  State<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends State<NotificationBell> {
  int unread = 0;
  Timer? _timer;

  Future<void> _refresh() async {
    var n = 0;
    if (api.loggedIn) {
      final r = await api.get(
        '/notifications/',
        query: {'unread_only': 'true', 'limit': '1'},
      );
      if (r.ok && r.json is Map) {
        n = ((r.json as Map)['unread_count'] as num?)?.toInt() ?? 0;
      }
    }
    if (mounted) setState(() => unread = n);
  }

  @override
  void initState() {
    super.initState();
    _refresh();
    api.addListener(_refresh);
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    api.removeListener(_refresh);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!api.loggedIn) return const SizedBox.shrink();
    return IconButton(
      tooltip: 'Notifications',
      onPressed: () async {
        await Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const NotificationsScreen()));
        _refresh();
      },
      icon: Badge(
        isLabelVisible: unread > 0,
        label: Text(unread > 99 ? '99+' : '$unread'),
        child: const Icon(Icons.notifications_outlined),
      ),
    );
  }
}

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  // Changing this key makes Loader fetch again (after mark-read / mark-all).
  int _reload = 0;

  void _refreshList() {
    if (mounted) setState(() => _reload++);
  }

  Future<void> _open(BuildContext context, Map<String, dynamic> n) async {
    if (n['is_read'] != true) {
      await api.post('/notifications/${n['notification_id']}/read');
      _refreshList();
    }
    final type = n['entity_type'] as String?;
    final id = (n['entity_id'] as num?)?.toInt();
    final opener = type == null ? null : notificationDestinations[type];
    if (opener != null && id != null && context.mounted) {
      opener(context, id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          TextButton(
            onPressed: () async {
              await act(
                context,
                () => api.post('/notifications/read-all'),
                success: 'All marked as read',
              );
              _refreshList();
            },
            child: const Text('Mark all read'),
          ),
        ],
      ),
      body: Loader(
        key: ValueKey(_reload),
        load: [() => api.get('/notifications/')],
        builder: (context, data) {
          final items = ((data[0] as Map)['items'] as List)
              .cast<Map<String, dynamic>>();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (items.isEmpty)
                const EmptyState(
                  'No notifications yet.',
                  icon: Icons.notifications_none,
                ),
              for (final n in items) _tile(context, n),
            ],
          );
        },
      ),
    );
  }

  Widget _tile(BuildContext context, Map<String, dynamic> n) {
    final read = n['is_read'] == true;
    final body = n['message'] as String?;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        onTap: () => _open(context, n),
        leading: Icon(
          read ? Icons.notifications_none : Icons.notifications_active,
          color: read ? Brand.muted : Brand.pink,
        ),
        title: Text(
          '${n['title']}',
          style: TextStyle(
            fontWeight: read ? FontWeight.w500 : FontWeight.w800,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (body != null && body.isNotEmpty) Text(body),
            Text(
              niceDate(n['sent_at']),
              style: const TextStyle(fontSize: 11, color: Brand.muted),
            ),
          ],
        ),
      ),
    );
  }
}
