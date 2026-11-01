import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import 'admin_screens.dart';
import 'csws_screens.dart';
import 'donor_dashboard.dart';
import 'donation_info.dart';
import 'home_nav.dart';
import 'donor_screens.dart';
import 'my_giving.dart';
import 'notifications_screen.dart';
import 'ops_screens.dart';
import 'cmo_screens.dart';
import 'pickup_map.dart';
import 'profile_screen.dart';
import 'records_screens.dart';
import 'report_screens.dart';
import 'sms_send_screen.dart';
import 'widgets.dart';
import 'change_password_screen.dart';

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
          'Encode SMS',
          Icons.mark_chat_read_outlined,
          NewReportScreen(smsEncode: true),
        ), // 2.2, UC-A3 8a: encode the Disaster Unit's SMS report
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
        _Tab('New report', Icons.edit_note, NewReportScreen()), // 2.1
        _Tab(
          'SMS report',
          Icons.sms_outlined,
          SmsSendScreen(),
        ), // 2.2, UC-CD1 11b: offline SMS to the Administrator
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
          PickupMapScreen(),
        ), // Door to Door pickups on the map (UC-CM1, Oct 11 notes)
        _Tab(
          'Deliveries',
          Icons.local_shipping_outlined,
          DeliveriesScreen(),
        ), // 5.4, 7.1, 8.1
      ];
    case Roles.cmo:
      return const [
        _Tab(
          'Acknowledge',
          Icons.verified_outlined,
          CmoScreen(),
        ), // Module 6, 9.5 (Oct 11: "Acknowledge", not "Confirm")
        // Oct 23 redesign: past acknowledgements and the summary per
        // report (7.4) live here, so the Acknowledge tab is today's work.
        _Tab('History', Icons.history, CmoHistoryScreen()),
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
        _Tab(
          'Records',
          Icons.folder_open_outlined,
          DonationRecordsScreen(),
        ), // 4.4, 4.5: own barangay's reports only (backend enforced)
        _Tab(
          'Donation info',
          Icons.account_balance_wallet_outlined,
          BarangayDonationInfoScreen(),
        ), // adviser item 7
      ];
    case Roles.donor:
    case Roles.org:
      return const [
        // Ivan (simple donor screens): Dashboard = landing-page banner and
        // the barangays that need help (9.4). Reports = the donor's own
        // giving: 4 cards, donation status, delivery status (UC-D3 / UC-R3).
        // Every report, active and done, is behind "See all reports".
        _Tab('Dashboard', Icons.dashboard_outlined, DonorDashboard()),
        // Oct 12 (team): the Disaster Reports view is a tab again (2.4,
        // 3.3: filters, fulfillment chips, sort), and My giving holds every
        // donation entry with its status and journey (UC-D3 / UC-R3).
        _Tab('Reports', Icons.article_outlined, DonorReportsTab()),
        _Tab('My giving', Icons.volunteer_activism_outlined, MyGivingScreen()),
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
List<Widget> _shellActions(BuildContext context) => [
  // A guest leaves from here, back to the landing page (not Settings).
  if (!api.loggedIn)
    TextButton.icon(
      onPressed: api.logout,
      style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
      icon: const Icon(Icons.home_outlined),
      label: const Text('Back to home page'),
    ),
];

/// The app shell: role-based navigation (bottom bar on phones, side rail
/// on tablets and Chrome) around the role's screens.
class RoleHome extends StatefulWidget {
  const RoleHome({super.key});

  @override
  State<RoleHome> createState() => _RoleHomeState();
}

class _RoleHomeState extends State<RoleHome> {
  int index = 0;

  static const _kLastTab = 'last_tab';

  /// Remember which tab the user opened, so a page refresh or app restart
  /// returns to it instead of the first tab. Signing in, browsing as a
  /// guest and Profile (where people sign out) start on the dashboard
  /// instead (testing, Oct 27).
  Future<void> _rememberTab(int i) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kLastTab, _allTabs[i].label);
    } catch (_) {}
  }

  Future<void> _restoreTab() async {
    try {
      final p = await SharedPreferences.getInstance();
      final label = p.getString(_kLastTab);
      if (label == null || !mounted || api.mustChangePassword) return;
      if (api.guest || label == 'Profile') return;
      final i = _allTabs.indexWhere((t) => t.label == label);
      if (i >= 0) setState(() => index = i);
    } catch (_) {}
  }

  void _selectTab(int i) {
    setState(() => index = i);
    _rememberTab(i);
  }

  List<_Tab> get _allTabs => [
    ..._tabsFor(api.role),
    const _Tab('Profile', Icons.person_outline, ProfileScreen()),
  ];

  /// A notification asked for an existing tab (home_nav.dart): switch to it,
  /// then run its follow-up (a pop-up or detail page over that tab).
  void _onHomeTarget() {
    final r = HomeNav.target.value;
    if (r == null || !mounted) return;
    final i = _allTabs.indexWhere((t) => t.label == r.to.tab);
    if (i >= 0 && i != index) setState(() => index = i);
    final then = r.to.then;
    if (then != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) then(context);
      });
    }
  }

  @override
  void dispose() {
    HomeNav.target.removeListener(_onHomeTarget);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    HomeNav.target.addListener(_onHomeTarget);
    _restoreTab();
    // I1: a temporary password must be changed first.
    if (api.mustChangePassword) {
      index = _tabsFor(api.role).length; // Profile is the last tab
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !api.mustChangePassword) return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const ChangePasswordScreen(forced: true),
          ),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tabs = _allTabs;
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
        actions: [const NotificationBell(), ..._shellActions(context), Gaps.h8],
      ),
      body: wide
          ? Row(
              children: [
                NavigationRail(
                  selectedIndex: index,
                  onDestinationSelected: _selectTab,
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
              onSelected: _selectTab,
              items: [
                for (final tab in tabs) FloatingNavItem(tab.icon, tab.label),
              ],
            ),
    );
  }
}
