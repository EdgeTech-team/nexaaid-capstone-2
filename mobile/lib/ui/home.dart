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

/// Menu for each role, following the manuscript use cases and the
/// wireframe sidebars ("Overview" first for office roles).
List<_Tab> _tabsFor(String? role) {
  const overview = _Tab('Overview', Icons.grid_view_rounded, DashboardScreen());
  const monitoring = _Tab(
    'Active Reports',
    Icons.monitor_heart_outlined,
    MonitoringScreen(),
  );
  switch (role) {
    case Roles.admin:
      return const [
        _Tab('System Overview', Icons.show_chart, DashboardScreen()), // UC-A4
        _Tab(
          'Report Validation',
          Icons.fact_check_outlined,
          AdminReportsScreen(),
        ), // UC-A3
        monitoring,
        _Tab(
          'User Management',
          Icons.manage_accounts_outlined,
          AccountsScreen(),
        ), // UC-A1
      ];
    case Roles.cswsUnit:
      return const [
        overview, // UC-CD2
        _Tab('New Report', Icons.edit_note, NewReportScreen()), // UC-CD1
        monitoring,
      ];
    case Roles.cswsMain:
      return const [
        overview, // UC-CM3
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
      ];
    case Roles.cmo:
      return const [
        _Tab('Overview', Icons.verified_outlined, CmoScreen()), // UC-C1/C2
      ];
    case Roles.drrmo:
      return const [
        _Tab(
          'Overview',
          Icons.fire_truck_outlined,
          DrrmoScreen(),
        ), // UC-DR1/DR2
      ];
    case Roles.barangay:
      return const [
        _Tab(
          'Incoming Aid',
          Icons.move_to_inbox_outlined,
          DeliveriesScreen(barangay: true),
        ), // UC-B1
        monitoring,
        overview, // UC-B2
      ];
    case Roles.donor:
    case Roles.org:
      return const [
        _Tab(
          'Dashboard',
          Icons.grid_view_rounded,
          DonorDashboard(),
        ), // UC-D3/D4, UC-R3/R4
        _Tab(
          'Validated Reports',
          Icons.volunteer_activism_outlined,
          ReportsFeed(),
        ), // UC-D2/R2
      ];
    default: // guest (no account): browse and donate only
      return const [
        _Tab(
          'Validated Reports',
          Icons.volunteer_activism_outlined,
          ReportsFeed(),
        ), // UC-D2
      ];
  }
}

/// Wireframe layout: white top bar with the "N" logo and a pink role pill;
/// MENU as a sidebar on wide screens, or behind the menu button on phones.
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
    final wide = MediaQuery.sizeOf(context).width >= 900;

    Widget menu({required bool drawer}) => _Menu(
      tabs: tabs,
      index: index,
      onSelect: (i) {
        setState(() => index = i);
        if (drawer) Navigator.of(context).pop();
      },
    );

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        titleSpacing: 16,
        title: Row(
          children: [
            const NexaLogo(size: 34),
            const SizedBox(width: 10),
            const Text(
              'NexaAid',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Brand.pinkSoft,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  api.loggedIn ? api.role! : 'Guest',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Brand.pinkDark,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
        actions: [
          if (wide)
            TextButton.icon(
              onPressed: api.logout,
              icon: const Icon(Icons.logout, color: Brand.muted),
              label: Text(
                api.loggedIn ? 'Logout' : 'Login',
                style: const TextStyle(color: Brand.muted),
              ),
            )
          else
            Builder(
              builder: (context) => IconButton(
                tooltip: 'Menu',
                icon: const Icon(Icons.menu),
                onPressed: () => Scaffold.of(context).openEndDrawer(),
              ),
            ),
          const SizedBox(width: 8),
        ],
      ),
      endDrawer: wide
          ? null
          : Drawer(child: SafeArea(child: menu(drawer: true))),
      body: wide
          ? Row(
              children: [
                Container(
                  width: 240,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    border: Border(right: BorderSide(color: Brand.line)),
                  ),
                  child: menu(drawer: false),
                ),
                Expanded(child: tabs[index].body),
              ],
            )
          : tabs[index].body,
    );
  }
}

class _Menu extends StatelessWidget {
  final List<_Tab> tabs;
  final int index;
  final ValueChanged<int> onSelect;
  const _Menu({
    required this.tabs,
    required this.index,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 20, 14, 14),
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 8, bottom: 12),
          child: Text(
            'MENU',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: Brand.ink,
              letterSpacing: 0.5,
            ),
          ),
        ),
        for (var i = 0; i < tabs.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Material(
              color: i == index ? Brand.pink : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              child: ListTile(
                dense: true,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                leading: Icon(
                  tabs[i].icon,
                  size: 20,
                  color: i == index ? Colors.white : Brand.muted,
                ),
                title: Text(
                  tabs[i].label,
                  style: TextStyle(
                    fontSize: 14,
                    color: i == index ? Colors.white : Brand.ink,
                    fontWeight: i == index ? FontWeight.w600 : null,
                  ),
                ),
                onTap: () => onSelect(i),
              ),
            ),
          ),
        const Divider(height: 24),
        ListTile(
          dense: true,
          leading: const Icon(Icons.logout, size: 20, color: Brand.muted),
          title: Text(api.loggedIn ? 'Logout' : 'Back to login'),
          onTap: api.logout,
        ),
      ],
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
