import 'package:flutter/material.dart';

import '../api.dart';
import '../design/gallery_screen.dart';
import '../dev_console.dart';
import 'admin_screens.dart';
import 'csws_screens.dart';
import 'donor_screens.dart';
import 'ops_screens.dart';
import 'pickup_board.dart';
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
          'Pickups',
          Icons.door_front_door_outlined,
          PickupBoardScreen(),
        ), // Door to Door pickups (UC-CM1)
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

/// Extra buttons in the signed-in app bar.
/// Mariquit (Sprint 0): add the notification bell here, e.g.
/// `const NotificationBell()`.
List<Widget> _shellActions(BuildContext context) => const [];

/// The app shell: role-based navigation (bottom bar on phones, side rail
/// on tablets and Chrome) around the role's screens.
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
    final wide = MediaQuery.sizeOf(context).width >= Breakpoints.expanded;
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;

    final body = AnimatedSwitcher(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : Motion.fast,
      child: KeyedSubtree(key: ValueKey(index), child: tabs[index].body),
    );

    return Scaffold(
      appBar: AppBar(
        titleSpacing: Space.md,
        title: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: cs.primary,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Icon(
                Icons.volunteer_activism,
                size: 18,
                color: cs.onPrimary,
              ),
            ),
            Gaps.h12,
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('NexaAid', style: t.titleMedium),
                  Text(
                    api.loggedIn ? (api.role ?? 'Signed in') : 'Guest',
                    overflow: TextOverflow.ellipsis,
                    style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [..._shellActions(context), Gaps.h8],
      ),
      body: wide
          ? Row(
              children: [
                NavigationRail(
                  selectedIndex: index,
                  onDestinationSelected: (i) => setState(() => index = i),
                  labelType: NavigationRailLabelType.all,
                  destinations: [
                    for (final tab in tabs)
                      NavigationRailDestination(
                        icon: Icon(tab.icon),
                        label: Text(tab.label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ],
            )
          : body,
      bottomNavigationBar: wide
          ? null
          : FloatingNavBar(
              selectedIndex: index,
              onSelected: (i) => setState(() => index = i),
              items: [
                for (final tab in tabs) FloatingNavItem(tab.icon, tab.label),
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
    final t = Theme.of(context).textTheme;
    void open(Widget page) =>
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));

    return ListView(
      padding: Space.page,
      children: [
        AppCard(
          child: Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: cs.primaryContainer,
                child: Icon(Icons.person, color: cs.onPrimaryContainer),
              ),
              Gaps.h16,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(api.email ?? 'Guest donor', style: t.titleMedium),
                    Text(
                      api.role ?? 'Not logged in',
                      style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SectionHeader('Appearance'),
        ValueListenableBuilder<ThemeMode>(
          valueListenable: AppTheme.mode,
          builder: (context, mode, _) => SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(
                value: ThemeMode.system,
                icon: Icon(Icons.brightness_auto_outlined),
                label: Text('System'),
              ),
              ButtonSegment(
                value: ThemeMode.light,
                icon: Icon(Icons.light_mode_outlined),
                label: Text('Light'),
              ),
              ButtonSegment(
                value: ThemeMode.dark,
                icon: Icon(Icons.dark_mode_outlined),
                label: Text('Dark'),
              ),
            ],
            selected: {mode},
            onSelectionChanged: (s) => AppTheme.mode.value = s.first,
          ),
        ),
        const SectionHeader('Developer tools'),
        AppCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: const Text('Server'),
                subtitle: Text(api.baseUrl),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.developer_mode),
                title: const Text('API console'),
                subtitle: const Text('Raw API forms and role checks'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => open(const DevConsole()),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.palette_outlined),
                title: const Text('Design system gallery'),
                subtitle: const Text(
                  'Every component, in dark mode and large text',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => open(const DesignGalleryScreen()),
              ),
            ],
          ),
        ),
        Gaps.v24,
        AppButton(
          api.loggedIn ? 'Log out' : 'Back to start',
          icon: Icons.logout,
          variant: AppButtonVariant.secondary,
          expand: true,
          onPressed: api.logout,
        ),
      ],
    );
  }
}
