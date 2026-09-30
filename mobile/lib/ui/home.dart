import 'package:flutter/material.dart';

import '../api.dart';
import '../dev_console.dart';
import 'donor_screens.dart';
import 'ops_screens.dart';
import 'report_screens.dart';
import 'widgets.dart';

class _Tab {
  final String label;
  final IconData icon;
  final Widget body;
  const _Tab(this.label, this.icon, this.body);
}

/// Bottom menu for each role, following the manuscript use cases.
List<_Tab> _tabsFor(String? role) {
  const dashboard = _Tab(
    'Dashboard',
    Icons.dashboard_outlined,
    DashboardScreen(),
  );
  switch (role) {
    case Roles.admin:
      return const [
        _Tab(
          'Reports',
          Icons.fact_check_outlined,
          AdminReportsScreen(),
        ), // UC-A3
        _Tab('Monitoring', Icons.monitor_heart_outlined, MonitoringScreen()),
        dashboard, // UC-A4
        _Tab(
          'Accounts',
          Icons.manage_accounts_outlined,
          AccountsScreen(),
        ), // UC-A1
      ];
    case Roles.cswsUnit:
      return const [
        _Tab('New report', Icons.edit_note, NewReportScreen()), // UC-CD1
        _Tab('Monitoring', Icons.monitor_heart_outlined, MonitoringScreen()),
        dashboard, // UC-CD2
      ];
    case Roles.cswsMain:
      return const [
        _Tab(
          'Donations',
          Icons.inventory_2_outlined,
          DonationsInScreen(),
        ), // UC-CM1
        _Tab(
          'Deliveries',
          Icons.local_shipping_outlined,
          DeliveriesScreen(),
        ), // UC-CM2
        dashboard, // UC-CM3
      ];
    case Roles.cmo:
      return const [
        _Tab('Confirmations', Icons.verified_outlined, CmoScreen()), // UC-C1/C2
      ];
    case Roles.drrmo:
      return const [
        _Tab(
          'Requests',
          Icons.fire_truck_outlined,
          DrrmoScreen(),
        ), // UC-DR1/DR2
      ];
    case Roles.barangay:
      return const [
        _Tab(
          'Incoming aid',
          Icons.move_to_inbox_outlined,
          DeliveriesScreen(barangay: true),
        ), // UC-B1
        _Tab('Monitoring', Icons.monitor_heart_outlined, MonitoringScreen()),
        dashboard, // UC-B2
      ];
    default: // Individual Donor, Relief Organization, guest
      return const [
        _Tab(
          'Donate',
          Icons.volunteer_activism_outlined,
          ReportsFeed(),
        ), // UC-D2/R2
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
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: cs.primaryContainer,
              child: Icon(Icons.person, color: cs.primary),
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
        FilledButton.tonalIcon(
          onPressed: api.logout,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          icon: const Icon(Icons.logout),
          label: Text(api.loggedIn ? 'Log out' : 'Back to login'),
        ),
      ],
    );
  }
}
