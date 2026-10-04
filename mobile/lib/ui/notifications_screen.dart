import 'dart:async';

import 'package:flutter/material.dart';

import '../report_detail_screen.dart';
import '../report_model.dart';
import 'donor_dashboard.dart';
import 'widgets.dart';

/// Where each notification type opens. Every module owner adds their own entry
/// when their detail screen exists, e.g.:
///
///   'donation_batch': (c, id) => Navigator.of(c).push(
///       MaterialPageRoute(builder: (_) => DonationBatchScreen(batchId: id))),
///
/// Unknown entity types simply mark the notification read and stay on the inbox.
typedef EntityOpener = void Function(BuildContext context, int entityId);
final Map<String, EntityOpener> notificationDestinations = {
  // ReportDetailScreen needs a full Report, and a notification only carries
  // the id, so fetch the report first, then open the screen.
  'report': (c, id) async {
    final r = await api.get('/reports/$id');
    if (!r.ok || r.json is! Map) return;
    if (!c.mounted) return;
    Navigator.of(c).push(
      MaterialPageRoute(
        builder: (_) => ReportDetailScreen(
          report: Report.fromJson(Map<String, dynamic>.from(r.json as Map)),
        ),
      ),
    );
  },
  // DonorDashboard is a tab body (no Scaffold), so wrap it to get an app bar
  // and a back button. It lists all of the donor's own donations.
  'donation': (c, id) => Navigator.of(c).push(
    MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('My donations')),
        body: const DonorDashboard(),
      ),
    ),
  ),
  // 'donation_batch': (c, id) => ...,
  // 'logistics_request': (c, id) => ...,
  // 'delivery': (c, id) => ...,
};

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
  