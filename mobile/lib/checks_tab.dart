import 'package:flutter/material.dart';

import 'api.dart';
import 'common.dart';

const _staffView = {
  Roles.admin,
  Roles.cswsMain,
  Roles.cswsUnit,
  Roles.barangay,
};

/// A GET endpoint and the roles that should get 200 from it
/// (taken from the require_role() calls in the backend routers).
class Check {
  final String label;
  final String path;
  final Set<String>? allowed; // null = public
  final bool anyUser; // any logged-in user
  const Check(this.label, this.path, {this.allowed, this.anyUser = false});

  /// Status this role should get. null = can't be known (e.g. may be 404).
  int expected(Api api) {
    if (allowed == null && !anyUser) return 200;
    if (!api.loggedIn) return 401;
    if (anyUser) return 200;
    return allowed!.contains(api.role) ? 200 : 403;
  }
}

const checks = <Check>[
  Check('Health', '/health'),
  Check('Who am I', '/health/secure', anyUser: true),
  Check('Reports: list', '/reports/', allowed: _staffView),
  Check(
    'Reports: monitoring (3.7)',
    '/reports/monitoring',
    allowed: _staffView,
  ),
  Check(
    'Donations: pending (3.6)',
    '/donations/pending',
    allowed: {Roles.admin, Roles.cswsMain},
  ),
  Check(
    'Donations: inventory (3.6)',
    '/donations/inventory',
    allowed: {Roles.admin, Roles.cswsMain},
  ),
  Check('CMO: pending (3.8)', '/cmo/donations/pending', allowed: {Roles.cmo}),
  Check('CMO: dashboard (3.8)', '/cmo/dashboard', allowed: {Roles.cmo}),
  Check('DRRMO: requests (3.9)', '/drrmo/requests', allowed: {Roles.drrmo}),
  Check('DRRMO: dashboard (3.9)', '/drrmo/dashboard', allowed: {Roles.drrmo}),
  Check(
    'Deliveries: list (3.10)',
    '/deliveries/',
    allowed: {Roles.admin, Roles.cswsMain, Roles.barangay},
  ),
  Check('Dashboard: summary', '/dashboard/summary', allowed: _staffView),
  Check(
    'Dashboard: reports',
    '/dashboard/reports-breakdown',
    allowed: _staffView,
  ),
  Check(
    'Dashboard: fulfillment',
    '/dashboard/fulfillment',
    allowed: _staffView,
  ),
  Check('Dashboard: logistics', '/dashboard/logistics', allowed: _staffView),
];

class ChecksTab extends StatefulWidget {
  const ChecksTab({super.key});

  @override
  State<ChecksTab> createState() => _ChecksTabState();
}

class _ChecksTabState extends State<ChecksTab> {
  final api = Api.instance;
  final results = <String, ApiResult>{};
  final expected = <String, int>{};
  bool busy = false;

  Future<void> runAll() async {
    setState(() {
      busy = true;
      results.clear();
      expected.clear();
    });
    for (final c in checks) {
      final r = await api.get(c.path);
      if (!mounted) return;
      setState(() {
        results[c.path] = r;
        expected[c.path] = c.expected(api);
      });
    }
    setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final done = results.length;
    final passed = checks
        .where((c) => results[c.path]?.status == expected[c.path])
        .length;
    return ListenableBuilder(
      listenable: api,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text(
            api.loggedIn
                ? 'Running as ${api.role ?? "?"} (${api.email})'
                : 'Running as guest (not logged in)',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          const Text(
            'Each GET is compared with the status this role should get: '
            '200 if the role is allowed, 403 if not, 401 as guest. '
            'Run it once per role.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              FilledButton(
                onPressed: busy ? null : runAll,
                child: const Text('Run all GET checks'),
              ),
              const SizedBox(width: 12),
              if (done > 0)
                Text(
                  '$passed / $done as expected',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: passed == done ? Colors.green : Colors.red,
                  ),
                ),
            ],
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: LinearProgressIndicator(),
            ),
          const SizedBox(height: 8),
          for (final c in checks) _row(c),
        ],
      ),
    );
  }

  Widget _row(Check c) {
    final r = results[c.path];
    final exp = expected[c.path];
    final match = r != null && r.status == exp;
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        dense: true,
        leading: r == null
            ? const Icon(Icons.radio_button_unchecked)
            : Icon(
                match ? Icons.check_circle : Icons.error,
                color: match ? Colors.green : Colors.red,
              ),
        title: Text(c.label),
        subtitle: Text(
          r == null
              ? c.path
              : '${c.path}\nexpected $exp, got ${r.status == 0 ? "ERR" : r.status}',
        ),
        trailing: r == null
            ? null
            : Chip(
                label: Text(
                  r.status == 0 ? 'ERR' : '${r.status}',
                  style: const TextStyle(color: Colors.white),
                ),
                backgroundColor: statusColor(r.status),
              ),
        onTap: r == null
            ? null
            : () => showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(c.path),
                  content: SingleChildScrollView(child: ResultBox(r)),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
