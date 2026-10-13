import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import 'batch_sheet.dart' show openDonationByQr;
import 'donor_dashboard.dart';
import 'home_nav.dart';
import 'ops_screens.dart' show showCmoEntryPopout;
import 'report_summary_card.dart' show NeedChips;
import 'widgets.dart';

/// Where each notification opens (Oct 11 notes, Jenises): always the page
/// that already exists in the app, a tab of the bottom menu with the right
/// view, never a second copy of it. A pop-up (report summary, donation
/// sheet) or a detail page that is normally opened from that tab can follow
/// on top. See home_nav.dart.
typedef EntityOpener = void Function(
  BuildContext context,
  int entityId,
  String? event,
);

void _go(
  BuildContext c,
  String tab, {
  String? view,
  int? id,
  void Function(BuildContext context)? then,
}) => HomeNav.go(c, HomeTarget(tab, view: view, id: id, then: then));

final Map<String, EntityOpener> notificationDestinations = {
  // Reports: the role's own reports page, then the report pop-up over it
  // (Concerns2.txt 2.1). The Administrator lands on Validate, on the list
  // the report is in, with that report first.
  'report': (c, id, event) async {
    switch (api.role) {
      case Roles.admin:
        var view = 'Pending';
        if (event != 'report_submitted') {
          final r = await api.get('/reports/$id');
          if (r.ok && r.json is Map) view = '${(r.json as Map)['status']}';
        }
        if (c.mounted) _go(c, 'Validate', view: view, id: id);
      case Roles.cswsUnit:
        _go(
          c,
          'Reports',
          view: 'status',
          then: (ctx) => showReportSheet(ctx, id),
        );
      default:
        _go(
          c,
          'Reports',
          view: 'validated',
          then: (ctx) => showReportSheet(ctx, id),
        );
    }
  },
  'donation': (c, id, event) => _openDonation(c, id),
  'delivery': (c, id, event) {
    switch (api.role) {
      case Roles.barangay:
        _go(c, 'Incoming aid');
      case Roles.cswsMain:
      case Roles.drrmo:
        _go(c, 'Deliveries');
      default:
        break; // no deliveries page for this role: stay on the inbox
    }
  },
  // DRRMO: its Logistics list. CSWS Main Office: Deliveries for a delivery
  // request, Pickups for a Door to Door pickup run.
  'logistics_request': (c, id, event) async {
    switch (api.role) {
      case Roles.drrmo:
        _go(
          c,
          'Logistics',
          view: event == 'logistics_requested' ? 'Pending' : null,
        );
      case Roles.cswsMain:
        final r = await api.get('/logistics/requests');
        final pickup =
            r.ok &&
            r.json is List &&
            (r.json as List).any(
              (x) =>
                  (x as Map)['request_id'] == id &&
                  x['request_type'] == 'Pickup',
            );
        if (c.mounted) _go(c, pickup ? 'Pickups' : 'Deliveries');
      default:
        break;
    }
  },
  // New organization / new donor: Accounts > Registrations, opened on that
  // account (its type and Reviewed / Not Reviewed section, outlined).
  'organization': (c, id, event) {
    if (api.role == Roles.admin) {
      _go(c, 'Accounts', view: 'registrations:org', id: id);
    }
  },
  'user': (c, id, event) {
    if (api.role == Roles.admin) {
      _go(
        c,
        'Accounts',
        view: event == 'donor_registered'
            ? 'registrations:donor'
            : 'registrations',
        id: id,
      );
    } else {
      _go(c, 'Profile'); // account created / password changed: your profile
    }
  },
};

Future<void> _openDonation(BuildContext c, int donationId) async {
  switch (api.role) {
    case Roles.cswsMain:
    case Roles.admin:
      // The notification points at one item; its QR reference opens the
      // whole donation entry, as a sheet over Receive (Main Office) or
      // Records (Administrator).
      final r = await api.get('/donations/$donationId/qr');
      if (!c.mounted) return;
      if (!r.ok || r.json is! Map) {
        ScaffoldMessenger.of(c).showSnackBar(
          const SnackBar(content: Text('This donation could not be found.')),
        );
        return;
      }
      final ref = '${(r.json as Map)['batch_reference']}';
      _go(
        c,
        api.role == Roles.admin ? 'Records' : 'Receive',
        then: (ctx) => openDonationByQr(ctx, ref),
      );
    case Roles.cmo:
      // problema_napud 4.1: the entry itself, in a pop-out over Acknowledge.
      _go(
        c,
        'Acknowledge',
        view: 'pending',
        then: (ctx) => showCmoEntryPopout(ctx, donationId),
      );
    case Roles.donor:
    case Roles.org:
      // The My giving tab (every donation entry), then that donation's
      // page, as when it is tapped in that list.
      _go(c, 'My giving', then: (ctx) => openMyDonation(ctx, donationId));
    default:
      break; // other roles have no donation page: stay on the inbox
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
  // problema_napud 2.1: a pop-out with everything already in it, closed
  // with the X at the top (no "See full details" page).
  await showDetailPopout(
    c,
    title: 'Report #${report['report_id']}',
    padding: EdgeInsets.zero, // ReportSheet has its own
    child: ReportSheet(report: report, names: names),
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

  /// problema_napud 2.2: every sitio the report names.
  String get _sitio {
    final saved = [
      for (final n in (report['sitio_names'] as List?) ?? const []) '$n',
    ];
    final ids =
        (report['sitio_ids'] as List?) ??
        [if (report['sitio_id'] != null) report['sitio_id']];
    if (saved.isEmpty && ids.isEmpty) return 'Whole barangay';
    final shown = saved.isNotEmpty
        ? saved
        : [
            for (final id in ids)
              if ((names?.of('sitios', id, fallback: '') ?? '').isNotEmpty)
                names!.of('sitios', id),
          ];
    if (shown.isEmpty) return 'Part of the barangay';
    return '${shown.length == 1 ? 'Sitio' : 'Sitios'} ${shown.join(', ')}';
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

    return Padding(
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
            _Section(label: 'What they need', child: NeedChips(needs)),

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

/// How often the bell asks for new notifications (problema_napud 2.1: the
/// Administrator should see a new report almost as soon as it is sent).
const notificationPollInterval = Duration(seconds: 8);

/// Opens what a notification is about (marks it read first).
Future<void> openNotification(BuildContext context, Map n) async {
  if (n['is_read'] != true) {
    await api.post('/notifications/${n['notification_id']}/read');
  }
  final type = n['entity_type'] as String?;
  final id = (n['entity_id'] as num?)?.toInt();
  final opener = type == null ? null : notificationDestinations[type];
  if (opener != null && id != null && context.mounted) {
    opener(context, id, n['type'] as String?);
  }
}

/// Bell icon with an unread badge. Checks every few seconds, after any
/// action in the app (api notifies listeners), and when the inbox is
/// closed. A notification that just arrived pops up as a short message
/// with "View", so nobody has to keep opening the inbox.
class NotificationBell extends StatefulWidget {
  const NotificationBell({super.key});

  @override
  State<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends State<NotificationBell> {
  int unread = 0;
  int? _newest; // id of the newest unread notification seen so far
  Timer? _timer;

  Future<void> _refresh() async {
    var n = 0;
    Map? top;
    if (api.loggedIn) {
      final r = await api.get(
        '/notifications/',
        query: {'unread_only': 'true', 'limit': '1'},
      );
      if (r.ok && r.json is Map) {
        n = ((r.json as Map)['unread_count'] as num?)?.toInt() ?? 0;
        final items = (r.json as Map)['items'];
        if (items is List && items.isNotEmpty && items.first is Map) {
          top = items.first as Map;
        }
      }
    }
    if (!mounted) return;
    final topId = (top?['notification_id'] as num?)?.toInt();
    final isNew = topId != null && _newest != null && topId > _newest!;
    if (topId != null && (_newest == null || topId > _newest!)) {
      _newest = topId;
    } else if (topId == null && _newest == null) {
      _newest = 0; // nothing unread yet: anything later is new
    }
    setState(() => unread = n);
    if (isNew) {
      final note = top!;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text('${note['title'] ?? 'New notification'}'),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: 'View',
            onPressed: () async {
              await openNotification(context, note);
              _refresh();
            },
          ),
        ),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _refresh();
    api.addListener(_refresh);
    _timer = Timer.periodic(notificationPollInterval, (_) => _refresh());
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
  Timer? _timer;
  String? _seen; // unread count + newest id last shown

  void _refreshList() {
    if (mounted) setState(() => _reload++);
  }

  /// While the inbox is open, new notifications appear by themselves.
  Future<void> _check() async {
    final r = await api.get('/notifications/', query: {'limit': '1'});
    if (!mounted || !r.ok || r.json is! Map) return;
    final m = r.json as Map;
    final items = m['items'];
    final top = items is List && items.isNotEmpty ? items.first : null;
    final now =
        '${m['unread_count']}|${top is Map ? top['notification_id'] : ''}';
    if (_seen != null && now != _seen) _refreshList();
    _seen = now;
  }

  @override
  void initState() {
    super.initState();
    _check();
    _timer = Timer.periodic(notificationPollInterval, (_) => _check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _open(BuildContext tileContext, Map<String, dynamic> n) async {
    // Open from this screen's context: refreshing the list rebuilds the
    // tiles, so the tapped tile's context would be gone and nothing opened.
    await openNotification(context, n);
    _refreshList();
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
