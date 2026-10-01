import 'package:flutter/material.dart';

import '../api.dart';
import '../dev_console.dart';
import 'admin_screens.dart';
import 'csws_screens.dart';
import 'donor_screens.dart';
import 'ops_screens.dart';
import 'records_screens.dart';
import 'report_screens.dart';
import 'widgets.dart';

class _Tab {
  final String label;
  final IconData icon;
  final Widget body;
  const _Tab(this.label, this.icon, this.body);
}

/// Bottom menu for each role, following the module list in Appendix H
/// (who may use which module) and the role dashboards of section 7.
List<_Tab> _tabsFor(String? role) {
  // Appendix H 2.4 View Validated Reports: every role. Roles that also
  // have 3.3 Priority-Based Report Filtering get the priority chips.
  const reports = _Tab(
    'Reports',
    Icons.article_outlined,
    ValidatedReportsScreen(),
  );
  // 2.4 + 2.5 Monitor Report Status, with priority filters (3.3).
  const reportsHub = _Tab('Reports', Icons.article_outlined, ReportsHub());
  switch (role) {
    case Roles.admin:
      return const [
        _Tab('Overview', Icons.dashboard_outlined, AdminDashboard()), // 9.1
        _Tab(
          'Validate',
          Icons.fact_check_outlined,
          AdminReportsScreen(),
        ), // 2.3, 2.4, 3.1, 3.3
        _Tab(
          'Monitoring',
          Icons.monitor_heart_outlined,
          MonitoringScreen(),
        ), // 2.5
        _Tab(
          'Records',
          Icons.folder_open_outlined,
          AdminRecordsScreen(),
        ), // 4.4, 4.5, 5.5, 6.3, 7.5, 8.5
        _Tab(
          'Accounts',
          Icons.manage_accounts_outlined,
          AccountsHub(),
        ), // 1.2, 1.3, 1.5
      ];
    case Roles.cswsUnit:
      return const [
        _Tab('Overview', Icons.dashboard_outlined, DashboardScreen()), // 9.3
        _Tab('New report', Icons.edit_note, NewReportScreen()), // 2.1, 2.2 SMS
        reportsHub, // 2.4, 2.5, 3.3
      ];
    case Roles.cswsMain:
      return const [
        _Tab('Overview', Icons.dashboard_outlined, CswsMainDashboard()), // 9.2
        reportsHub, // 2.4, 2.5, 3.3
        _Tab(
          'Receive',
          Icons.qr_code_scanner,
          ReceiveScreen(),
        ), // Module 5, 4.4
        _Tab(
          'Deliveries',
          Icons.local_shipping_outlined,
          DeliveriesScreen(),
        ), // 5.4, 7.1, 8.1
      ];
    case Roles.cmo:
      return const [
        _Tab(
          'Confirmations',
          Icons.verified_outlined,
          CmoScreen(),
        ), // Module 6, 9.5
        reports, // 2.4
      ];
    case Roles.drrmo:
      return const [
        _Tab(
          'Logistics',
          Icons.fire_truck_outlined,
          DrrmoScreen(),
        ), // Module 7, 9.6
        _Tab(
          'Deliveries',
          Icons.local_shipping_outlined,
          DeliveriesScreen(readOnly: true),
        ), // 8.5
        reports, // 2.4
      ];
    case Roles.barangay:
      return const [
        _Tab(
          'Incoming aid',
          Icons.move_to_inbox_outlined,
          DeliveriesScreen(barangay: true),
        ), // 8.2-8.5
        _Tab('Overview', Icons.dashboard_outlined, BarangayDashboard()), // 9.7
        reports, // 2.4
      ];
    case Roles.donor:
    case Roles.org:
      return const [
        _Tab('Dashboard', Icons.dashboard_outlined, DonorDashboard()), // 9.4
        _Tab(
          'Donate',
          Icons.volunteer_activism_outlined,
          ReportsFeed(),
        ), // 2.4, 3.3, Module 4
      ];
    default: // guest: public homepage (1.4)
      return const [
        _Tab('Donate', Icons.volunteer_activism_outlined, ReportsFeed()),
      ];
  }
}

class RoleHome extends StatefulWidget {
  const RoleHome({super.key});

  @override
  State<RoleHome> createState() => _RoleHomeState();
}

class _RoleHomeState extends State<RoleHome> {
  int index = 0;

  @override
  Widget build(BuildContext context) {
    final tabs = [
      ..._tabsFor(api.role),
      const _Tab('Profile', Icons.person_outline, ProfileScreen()),
    ];
    if (index >= tabs.length) index = 0;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.volunteer_activism, size: 22),
            const SizedBox(width: 8),
            const Text(
              'NexaAid',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                api.loggedIn ? '· ${api.role}' : '· Guest',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14),
              ),
            ),
          ],
        ),
      ),
      body: tabs[index].body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => setState(() => index = i),
        destinations: [
          for (final t in tabs)
            NavigationDestination(icon: Icon(t.icon), label: t.label),
        ],
      ),
    );
  }
}

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const PageHeader('Profile'),
        Card(
          child: ListTile(
            leading: const CircleAvatar(
              backgroundColor: Brand.pinkSoft,
              child: Icon(Icons.person, color: Brand.pink),
            ),
            title: Text(api.email ?? 'Guest donor'),
            subtitle: Text(api.role ?? 'Not logged in'),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: const Text('Server'),
                subtitle: Text(api.baseUrl),
              ),
              ListTile(
                leading: const Icon(Icons.developer_mode),
                title: const Text('Developer tools'),
                subtitle: const Text('Raw API forms and role checks'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const DevConsole())),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: api.logout,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          icon: const Icon(Icons.logout),
          label: Text(api.loggedIn ? 'Log out' : 'Back to login'),
        ),
      ],
    );
  }
}
