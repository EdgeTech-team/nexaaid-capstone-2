import 'dart:async';

import 'package:flutter/material.dart';

import '../../shared/widgets/kept_views.dart';
import '../../core/app_routes.dart';
import '../../core/api.dart';
import 'account_detail_screen.dart';
import 'account_form.dart' show AccountsScreen;
import '../receiving/csws_screens.dart' show ActivityList;
import '../donations/donation_info.dart' show BarangayDonationInfoScreen;
import 'private_file_view.dart';
import '../../shared/widgets/paginated_list.dart';
import '../donations/paged_donation_entries.dart' show searchDebounce;
import '../../shared/widgets/widgets.dart';
import '../donations/entry_report_views.dart';
import '../home/home_nav.dart';
import '../donations/item_amounts.dart';

// ---------------------------------------------------------------------------
// UC-A4 / manuscript 7.7 Administrator dashboard
// ---------------------------------------------------------------------------
class AdminDashboard extends StatelessWidget {
  const AdminDashboard({super.key});

  /// 5.1: a tile opens the tab that already lists what it counts (Oct 11
  /// notes: move to the existing page instead of opening a copy of it).
  void _go(BuildContext context, String tab, String view) =>
      HomeNav.go(context, HomeTarget(tab, view: view));

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [
        () => api.get('/dashboard/admin'),
        () => api.get('/donations/entries'),
      ],
      builder: (context, data) {
        final m = data[0] as Map;
        final entries = data[1] as Map;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            PageHeader('Administrator Dashboard', subtitle: roleLine()),
            StatGrid([
              StatTile(
                'Active users',
                '${m['active_users']} / ${m['total_users']}',
                Icons.people_outline,
                onTap: () => _go(context, 'Accounts', 'active'),
              ),
              // The Administrator now only reviews organizations (accounts
              // activate automatically), so this says "review", not "approve".
              StatTile(
                'Registrations to review',
                '${m['pending_registrations'] ?? m['pending_organizations']}',
                Icons.apartment_outlined,
                color: const Color(0xFFEF6C00),
                onTap: () => _go(context, 'Accounts', 'registrations'),
              ),
              StatTile(
                'Reports to validate',
                '${m['pending_validations']}',
                Icons.fact_check_outlined,
                color: const Color(0xFFEF6C00),
                onTap: () => _go(context, 'Validate', 'Pending'),
              ),
              StatTile(
                'Validated reports',
                '${m['validated_reports']}',
                Icons.verified_outlined,
                color: const Color(0xFF2E7D32),
                // Validate > Validated has the fulfillment chips and sort.
                onTap: () => _go(context, 'Validate', 'Validated'),
              ),
              // Team rule: count ENTRIES (one per donor submission), not rows.
              StatTile(
                'Donation entries',
                '${entries['total_entries']}',
                Icons.volunteer_activism_outlined,
                note: '${m['total_donations']} items · tap to view',
                // Records > Donations: every entry with filters and sort.
                onTap: () => HomeNav.go(context, const HomeTarget('Records')),
              ),
              // 9.1 (testing, Oct 19): "Held donations" removed. It is not
              // in the manuscript; held donations are in Records > Needs
              // attention > On Hold.
            ]),
            const SectionTitle('Donation entries per report'),
            EntrySummaryList(entries),
            const SectionTitle('System activity log'),
            ActivityList((m['recent_activity'] as List).cast<Map>()),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// UC-A1 Manage internal accounts + UC-A2 Review organization registration
// ---------------------------------------------------------------------------
class AccountsHub extends StatefulWidget {
  /// Which section to show first: accounts (with active / deactivated as a
  /// filter), registrations (donors + organizations), donation, new.
  /// The old names 'active' and 'deactivated' still work.
  final String initialView;
  const AccountsHub({super.key, this.initialView = 'accounts'});

  @override
  State<AccountsHub> createState() => _AccountsHubState();
}

class _AccountsHubState extends State<AccountsHub>
    with HomeTargetListener<AccountsHub> {
  late String view = _section(widget.initialView);
  late String status = _statusOf(widget.initialView);

  /// The registration a notification points at: ('org' | 'donor', id).
  (String, int)? _focus;
  int _focusSeq = 0;

  static String _section(String v) =>
      const {'active', 'deactivated', 'all'}.contains(v) ? 'accounts' : v;

  static String _statusOf(String v) =>
      v == 'active' || v == 'deactivated' ? v : 'all';

  // A registration notification opens Accounts > Registrations on that
  // account (home_nav): view "registrations:org" or "registrations:donor".
  @override
  String get homeTab => 'Accounts';

  @override
  void applyHomeTarget(HomeTarget target) {
    final v = target.view;
    if (v == null) return;
    if (v.startsWith('registrations')) {
      view = 'registrations';
      final type = v.contains(':') ? v.split(':')[1] : null;
      _focus = type != null && target.id != null ? (type, target.id!) : null;
      _focusSeq++;
      return;
    }
    if (v == 'orgs') {
      view = 'registrations';
      return;
    }
    view = _section(v);
    if (view == 'accounts') status = _statusOf(v);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Scrolls sideways on narrow phones instead of overflowing.
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              // problema_napud 1.2: Active and Deactivated are one section;
              // the status is a filter beside the role.
              ButtonSegment(value: 'accounts', label: Text('All accounts')),
              // Individual donors and organizations reviewed in one list.
              ButtonSegment(
                value: 'registrations',
                label: Text('Registrations'),
              ),
              // Adviser item 7: any barangay's donation-sending info, e.g.
              // a barangay without a representative yet, or a wrong number.
              ButtonSegment(value: 'donation', label: Text('Donation info')),
              ButtonSegment(value: 'new', label: Text('New account')),
            ],
            selected: {view},
            onSelectionChanged: (s) {
              setState(() {
                view = s.first;
                _focus = null;
              });
              // NF-002: /admin/accounts/registrations, ...
              AppRoutes.instance.viewChanged(homeTab, view);
            },
          ),
        ),
        // UAT (Nov 14): sections opened once stay loaded when switching.
        Expanded(
          child: KeptViews(
            current: view,
            builder: (context, v) => switch (v) {
              'registrations' => RegistrationsScreen(
                key: ValueKey('registrations-$_focusSeq'),
                focusType: _focus?.$1,
                focusId: _focus?.$2,
              ),
              'donation' => const BarangayDonationInfoScreen(),
              'new' => const AccountsScreen(),
              _ => UsersScreen(
                key: ValueKey('accounts-$status'),
                status: status,
              ),
            },
          ),
        ),
      ],
    );
  }
}

class UsersScreen extends StatefulWidget {
  /// I2 / problema_napud 1.2: 'all', 'active' or 'deactivated' to start
  /// with; the Administrator changes it with the Status filter.
  final String status;
  const UsersScreen({super.key, this.status = 'all'});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  String role = '';
  String q = '';
  late String status = widget.status;

  // NF-003: 20 accounts per page; role, status and search are filtered by
  // the server (GET /admin/users with limit / offset).
  late final PagedController _list = PagedController(fetch: _fetch());

  PageFetch _fetch() {
    final filters = {
      if (status != 'all') 'active': '${status == 'active'}',
      if (role.isNotEmpty) 'role': role,
      if (q.isNotEmpty) 'q': q,
    };
    return (offset, limit) => api.get(
      '/admin/users',
      query: {...filters, 'limit': '$limit', 'offset': '$offset'},
    );
  }

  /// A filter changed: back to page 1 with the new filters.
  void _filter(VoidCallback change) {
    setState(change);
    _list.refresh(fetch: _fetch());
  }

  @override
  void dispose() {
    _list.dispose();
    super.dispose();
  }

  /// For a deactivated account, a labeled line with the reason the
  /// Administrator gave (or a note when none was recorded).
  String _reasonLine(Map u) {
    if (u['is_active'] == true) return '';
    final r = '${u['deactivation_reason'] ?? ''}'.trim();
    return '\nDeactivated · Reason: ${r.isEmpty ? 'No reason was recorded' : r}';
  }

  @override
  Widget build(BuildContext context) {
    return PagedListView(
      controller: _list,
      header: [
        const PageHeader(
          'All accounts',
          subtitle:
              'Active and deactivated accounts. Tap one to see its '
              'details, edit it, deactivate it, restore it or delete it.',
        ),
        TextField(
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            labelText: 'Search name or email',
          ),
          onSubmitted: (v) => _filter(() => q = v.trim()),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              flex: 3,
              child: DropdownButtonFormField<String>(
                initialValue: role,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Role'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('All roles')),
                  for (final r in const [
                    Roles.admin,
                    Roles.donor,
                    Roles.org,
                    Roles.cmo,
                    Roles.cswsMain,
                    Roles.cswsUnit,
                    Roles.barangay,
                    Roles.drrmo,
                  ])
                    DropdownMenuItem(value: r, child: Text(r)),
                ],
                onChanged: (v) => _filter(() => role = v ?? ''),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: DropdownButtonFormField<String>(
                key: const ValueKey('accounts-status'),
                initialValue: status,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Status'),
                items: const [
                  DropdownMenuItem(value: 'all', child: Text('All')),
                  DropdownMenuItem(value: 'active', child: Text('Active')),
                  DropdownMenuItem(
                    value: 'deactivated',
                    child: Text('Deactivated'),
                  ),
                ],
                onChanged: (v) => _filter(() => status = v ?? 'all'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ListenableBuilder(
          listenable: _list,
          builder: (context, _) => Text(
            '${_list.total ?? _list.items.length} '
            '${status == 'all' ? '' : '$status '}accounts',
            style: const TextStyle(color: Brand.muted),
          ),
        ),
        const SizedBox(height: 6),
      ],
      empty: const EmptyState('No accounts to show.'),
      itemBuilder: (context, u) => Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: u['is_active'] == true
                ? Brand.pinkSoft
                : Colors.black12,
            child: Icon(
              u['is_active'] == true ? Icons.person : Icons.person_off_outlined,
              color: u['is_active'] == true ? Brand.pink : Colors.grey,
            ),
          ),
          title: Text('${u['name']}'),
          subtitle: Text(
            '${u['email']}\n${u['role']}'
            '${u['assigned_barangay'] != null ? ' · ${u['assigned_barangay']}' : ''}'
            '${u['organization'] != null ? ' · ${u['organization']} (${u['organization_status']})' : ''}'
            '${_reasonLine(u)}',
          ),
          isThreeLine: true,
          onTap: () async {
            final deleted = await Navigator.of(context).push<bool>(
              MaterialPageRoute(
                builder: (_) =>
                    AccountDetailScreen(userId: u['user_id'] as int),
              ),
            );
            if (deleted == true && mounted) _list.reloadQuietly();
          },
          // UC-A1: tap the row for details, Edit details and
          // Deactivate (account_detail_screen.dart).
          trailing: const Icon(Icons.chevron_right),
        ),
      ),
    );
  }
}

/// Why the Administrator deletes a registration (required, emailed).
const deleteAccountReasons = [
  'Fake ID',
  'Invalid document',
  'ID does not match the person',
  'Unreadable ID or document',
  'Duplicate account',
  'Other',
];

/// UC-A2 + Oct 11 notes (Jenises): new registrations of individual donors
/// and organizations in one list. Accounts are active as soon as they
/// register; the Administrator reviews each registration here (Reviewed /
/// Not Reviewed), with a type filter, search and sorting.
class RegistrationsScreen extends StatefulWidget {
  /// The registration a notification points at ('org' or 'donor' and its
  /// id): the list opens on its type and Reviewed / Not Reviewed section,
  /// scrolls to it and outlines it (problema_napud 1.1).
  final String? focusType;
  final int? focusId;
  const RegistrationsScreen({super.key, this.focusType, this.focusId});

  @override
  State<RegistrationsScreen> createState() => _RegistrationsScreenState();
}

class _RegistrationsScreenState extends State<RegistrationsScreen> {
  String review = 'all'; // all | done | not
  String kind = 'all'; // all | donors | orgs
  // NF-008 (D6): the review queue first (not reviewed, Government types
  // first, then newest). newest | oldest | name | review
  String sort = 'review';
  String search = ''; // what the list was loaded for
  Timer? _typing;
  final Set<String> _busy = {};

  /// The registration a notification is about, shown first and outlined.
  Map<String, dynamic>? _focus;

  // NF-003: organizations and donors in one list, filtered, sorted and 20
  // per page on the server (GET /admin/registrations). It used to be built
  // here from two full lists.
  late final PagedController _list = PagedController(fetch: _fetch());

  PageFetch _fetch() {
    final filters = {
      'review': review,
      'kind': kind,
      'sort': sort,
      if (search.trim().isNotEmpty) 'q': search.trim(),
    };
    return (offset, limit) => api.get(
      '/admin/registrations',
      query: {...filters, 'limit': '$limit', 'offset': '$offset'},
    );
  }

  void _filter(VoidCallback change) {
    setState(change);
    _list.refresh(fetch: _fetch());
  }

  /// Search is sent once typing stops.
  void _search(String v) {
    _typing?.cancel();
    _typing = Timer(searchDebounce, () {
      if (mounted && v.trim() != search.trim()) _filter(() => search = v);
    });
  }

  @override
  void initState() {
    super.initState();
    if (widget.focusId != null) _loadFocus(first: true);
  }

  @override
  void dispose() {
    _typing?.cancel();
    _list.dispose();
    super.dispose();
  }

  DateTime? _when(dynamic v) =>
      v == null ? null : DateTime.tryParse('$v')?.toLocal();

  /// A server row as the card shows it.
  Map<String, dynamic> _item(Map r) => {
    'type': r['type'],
    'id': r['id'],
    'name': '${r['name']}',
    'email': '${r['email']}',
    'when': _when(r['created_at']),
    'reviewed': r['reviewed'] == true,
    if (r['org'] != null) 'org': r['org'],
  };

  /// Open on the notified registration: its type and review section, with
  /// it first (problema_napud 1.1).
  Future<void> _loadFocus({bool first = false}) async {
    final r = await api.get(
      '/admin/registrations',
      query: {'focus_type': ?widget.focusType, 'focus_id': '${widget.focusId}'},
    );
    if (!mounted || !r.ok || r.json is! List || (r.json as List).isEmpty) {
      return;
    }
    final item = _item((r.json as List).first as Map);
    if (first) {
      _filter(() {
        _focus = item;
        review = item['reviewed'] == true ? 'done' : 'not';
        kind = item['type'] == 'org' ? 'orgs' : 'donors';
      });
    } else {
      setState(() => _focus = item);
    }
  }

  Future<void> _setReviewed(Map<String, dynamic> i, bool value) async {
    final key = '${i['type']}-${i['id']}';
    if (_busy.contains(key)) return;
    setState(() => _busy.add(key));
    final r = await api.patch(
      i['type'] == 'org'
          ? '/admin/organizations/${i['id']}/review'
          : '/admin/users/${i['id']}/review',
      body: {'reviewed': value},
    );
    if (!mounted) return;
    setState(() => _busy.remove(key));
    // The list and the counts reload by themselves after a change.
    if (r.ok && _focus != null && i['id'] == _focus!['id']) _loadFocus();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          !r.ok
              ? 'Could not update the review: ${r.errorText}'
              : value
              ? '${i['name']} marked Reviewed'
              : '${i['name']} marked Not Reviewed',
        ),
      ),
    );
  }

  /// NF-008 (D6) Mark verified: the Verified badge then shows to CSWS and
  /// on the transparency dashboard.
  Future<void> _verifyOrg(Map<String, dynamic> i) async {
    final r = await act(
      context,
      () => api.post('/admin/organizations/${i['id']}/verify', body: const {}),
      success: '${i['name']} marked Verified',
    );
    if (r.ok && _focus != null && i['id'] == _focus!['id']) _loadFocus();
  }

  /// NF-008 (D6) Deactivate: fake or wrong documents. The reason is
  /// required and emailed to the organization.
  Future<void> _deactivateOrg(Map<String, dynamic> i) async {
    final v = await formDialog(
      context,
      title: 'Deactivate ${i['name']}?',
      message:
          'The organization can no longer sign in. The reason is emailed to '
          'it. You can activate the account again from View account.',
      fields: const [
        DialogField(
          'reason',
          'Reason (emailed to the organization)',
          multiline: true,
          hint: 'e.g. The ID photo does not match the contact person.',
        ),
      ],
      confirm: 'Deactivate',
    );
    if (v == null || !mounted) return;
    final r = await act(
      context,
      () => api.post(
        '/admin/organizations/${i['id']}/deactivate',
        body: {'reason': v['reason']},
      ),
      success: '${i['name']} deactivated. The reason was emailed.',
    );
    if (r.ok && _focus != null && i['id'] == _focus!['id']) _loadFocus();
  }

  /// Registration review: a fake ID or invalid document. The account is
  /// removed in one step (it signed in right after registering), with a
  /// required reason that is kept in the audit log and emailed to them.
  Future<void> _deleteAccount(Map<String, dynamic> i, int accountId) async {
    final v = await formDialog(
      context,
      title: 'Delete ${i['name']}?',
      message:
          'The account is removed and can no longer sign in. Its records '
          'stay, without personal data. The reason is emailed to them. This '
          'cannot be undone.',
      fields: const [
        DialogField(
          'reason',
          'Reason',
          options: deleteAccountReasons,
        ),
        DialogField(
          'details',
          'Details (optional)',
          required: false,
          multiline: true,
          hint: 'e.g. The ID photo does not match the name.',
        ),
      ],
      confirm: 'Delete account',
    );
    if (v == null || !mounted) return;
    final details = (v['details'] ?? '').trim();
    final reason = details.isEmpty ? v['reason']! : '${v['reason']}: $details';
    final r = await act(
      context,
      () => api.post(
        '/admin/users/$accountId/delete',
        body: {'reason': reason},
      ),
      success: '${i['name']} deleted. The reason was emailed.',
    );
    if (!mounted || !r.ok) return;
    if (_focus != null && i['id'] == _focus!['id']) {
      setState(() => _focus = null);
    }
    _list.refresh(fetch: _fetch());
  }

  Widget _card(Map<String, dynamic> i, {bool highlighted = false}) => Padding(
    padding: const EdgeInsets.only(bottom: Space.sm),
    child: _RegistrationCard(
      highlighted: highlighted,
      item: i,
      busy: _busy.contains('${i['type']}-${i['id']}'),
      onReview: (v) => _setReviewed(i, v),
      onVerify: () => _verifyOrg(i),
      onDeactivate: () => _deactivateOrg(i),
      onDelete: (accountId) => _deleteAccount(i, accountId),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final focus = _focus;
    return Loader(
      load: [() => api.get('/admin/registrations/counts')],
      builder: (context, data) {
        final counts = data[0] is Map ? data[0] as Map : const {};
        return PagedListView(
          controller: _list,
          header: [
            const PageHeader(
              'Registrations',
              subtitle:
                  'Individual donors and organizations. Their accounts are '
                  'active as soon as they register; review each one here.',
            ),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: 'all',
                  label: Text('All (${counts['all'] ?? 0})'),
                ),
                ButtonSegment(
                  value: 'done',
                  label: Text('Reviewed (${counts['reviewed'] ?? 0})'),
                ),
                ButtonSegment(
                  value: 'not',
                  label: Text('Not Reviewed (${counts['not_reviewed'] ?? 0})'),
                ),
              ],
              selected: {review},
              onSelectionChanged: (s) => _filter(() => review = s.first),
            ),
            Gaps.v12,
            Wrap(
              spacing: Space.xs,
              children: [
                for (final (value, label) in const [
                  ('all', 'Everyone'),
                  ('donors', 'Individual donors'),
                  ('orgs', 'Organizations'),
                ])
                  ChoiceChip(
                    label: Text(label),
                    selected: kind == value,
                    onSelected: (_) => _filter(() => kind = value),
                  ),
              ],
            ),
            Gaps.v12,
            AppTextField(
              label: 'Search name or email',
              icon: Icons.search,
              onChanged: _search,
            ),
            Gaps.v12,
            DropdownButtonFormField<String>(
              initialValue: sort,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Sort by'),
              items: const [
                DropdownMenuItem(
                  value: 'review',
                  child: Text('Review queue (Government first)'),
                ),
                DropdownMenuItem(value: 'newest', child: Text('Newest first')),
                DropdownMenuItem(value: 'oldest', child: Text('Oldest first')),
                DropdownMenuItem(value: 'name', child: Text('Name (A to Z)')),
              ],
              onChanged: (v) => _filter(() => sort = v ?? 'review'),
            ),
            Gaps.v16,
            if (focus != null) _card(focus, highlighted: true),
          ],
          empty: focus != null
              ? const SizedBox.shrink()
              : EmptyState(
                  review == 'not'
                      ? 'Every registration has been reviewed.'
                      : 'No registrations to show.',
                ),
          // The notified registration is already on top.
          itemBuilder: (context, r) =>
              focus != null &&
                  r['type'] == focus['type'] &&
                  r['id'] == focus['id']
              ? const SizedBox.shrink()
              : _card(_item(r)),
        );
      },
    );
  }
}

/// One registration: who, when, Reviewed or not, and the review button.
/// Organizations show their details and supporting document; donors open
/// their account (with their valid ID).
class _RegistrationCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final bool busy;
  final bool highlighted;
  final ValueChanged<bool> onReview;
  final VoidCallback? onVerify;
  final VoidCallback? onDeactivate;

  /// Delete the account (fake ID / invalid document), with its user id.
  final void Function(int accountId)? onDelete;
  const _RegistrationCard({
    required this.item,
    required this.busy,
    required this.onReview,
    this.onVerify,
    this.onDeactivate,
    this.onDelete,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final muted = t.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    final org = item['type'] == 'org';
    final o = item['org'] as Map?;
    final reviewed = item['reviewed'] == true;
    final when = item['when'] as DateTime?;
    // NF-008 (D6): Unverified / Verified / Deactivated, and the warning.
    final state =
        '${o?['verification_state'] ?? (reviewed ? 'Verified' : 'Unverified')}';
    final warning = o?['warning'] as String?;
    // Donors: their account. Organizations: the organization's account.
    final accountId = org
        ? (o?['user_id'] as num?)?.toInt()
        : (item['id'] as num?)?.toInt();
    return AppCard(
      color: highlighted ? cs.primaryContainer.withValues(alpha: 0.35) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                org ? Icons.apartment_outlined : Icons.person_outline,
                color: cs.primary,
              ),
              Gaps.h12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${item['name']}', style: t.titleMedium),
                    Text(
                      org
                          ? '${o?['organization_category'] ?? 'Organization'}'
                                ' · ${o?['organization_type'] ?? ''}'
                          : 'Individual donor',
                      style: muted,
                    ),
                  ],
                ),
              ),
              Gaps.h8,
              org
                  ? StatusChip(switch (state) {
                      'Verified' => 'Confirmed',
                      'Deactivated' => 'Cancelled',
                      _ => 'Pending',
                    }, label: state)
                  : StatusChip(reviewed ? 'Reviewed' : 'Not Reviewed'),
            ],
          ),
          Gaps.v8,
          Text('${item['email']}', style: t.bodyMedium),
          Text(
            when == null
                ? 'Registered: unknown date'
                : 'Registered ${niceDate(when.toIso8601String())}',
            style: muted,
          ),
          if (org && warning != null) ...[
            Gaps.v8,
            StatusChip('On Hold', label: warning),
          ],
          if (org && o?['deactivation_reason'] != null) ...[
            Gaps.v8,
            Text('Deactivated: ${o!['deactivation_reason']}', style: muted),
          ],
          if (org && o?['contact_id_missing'] == true) ...[
            Gaps.v8,
            const StatusChip(
              'Cancelled',
              label: 'Contact person\'s ID missing',
            ),
          ],
          if (org) ...[
            Gaps.v8,
            Text(
              'Registration no.: ${o?['registration_no'] ?? 'Not provided'}'
              '\nContact: ${o?['contact_person'] ?? 'Not provided'}'
              '${(o?['address'] ?? '').toString().trim().isEmpty ? '' : '\nAddress: ${o!['address']}'}',
              style: t.bodyMedium,
            ),
            Gaps.v12,
            _OrgDocument(item['id'] as int),
          ],
          Gaps.v12,
          Row(
            children: [
              if (accountId != null) ...[
                Expanded(
                  child: AppButton(
                    'View account',
                    icon: Icons.badge_outlined,
                    variant: AppButtonVariant.text,
                    expand: true,
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => AccountDetailScreen(userId: accountId),
                      ),
                    ),
                  ),
                ),
                Gaps.h8,
              ],
              if (!org)
                Expanded(
                  child: AppButton(
                    reviewed ? 'Mark Not Reviewed' : 'Mark Reviewed',
                    icon: reviewed ? Icons.undo : Icons.fact_check_outlined,
                    variant: reviewed
                        ? AppButtonVariant.secondary
                        : AppButtonVariant.tonal,
                    loading: busy,
                    expand: true,
                    onPressed: () => onReview(!reviewed),
                  ),
                )
              else if (state == 'Unverified')
                Expanded(
                  child: AppButton(
                    'Mark verified',
                    icon: Icons.verified_outlined,
                    variant: AppButtonVariant.tonal,
                    loading: busy,
                    expand: true,
                    onPressed: onVerify,
                  ),
                )
              else if (state == 'Verified')
                Expanded(
                  child: AppButton(
                    'Mark Unverified',
                    icon: Icons.undo,
                    variant: AppButtonVariant.secondary,
                    loading: busy,
                    expand: true,
                    onPressed: () => onReview(false),
                  ),
                ),
            ],
          ),
          // Accounts sign in right away: check the ID and documents now.
          if (!reviewed) ...[
            Gaps.v8,
            Text(
              org
                  ? 'Check the contact person\'s valid ID and the supporting '
                        'document before marking it verified.'
                  : 'Check the valid ID (needed for Door to Door pickups) '
                        'before marking it reviewed.',
              key: const ValueKey('registration-check-reminder'),
              style: muted,
            ),
          ],
          // NF-008 (D6): fake or wrong documents.
          Wrap(
            alignment: WrapAlignment.end,
            spacing: Space.xs,
            children: [
              if (org && state != 'Deactivated' && onDeactivate != null)
                TextButton.icon(
                  onPressed: onDeactivate,
                  style: TextButton.styleFrom(foregroundColor: cs.error),
                  icon: const Icon(Icons.block, size: 18),
                  label: const Text('Deactivate'),
                ),
              if (accountId != null && onDelete != null)
                TextButton.icon(
                  key: const ValueKey('registration-delete'),
                  onPressed: () => onDelete!(accountId),
                  style: TextButton.styleFrom(foregroundColor: cs.error),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Delete account'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The organization's supporting document, or a flag when it is missing,
/// unreadable, or an old unverified link (UC-A2 alt 4a).
class _OrgDocument extends StatelessWidget {
  final int organizationId;
  const _OrgDocument(this.organizationId);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ApiResult>(
      future: api.get('/admin/organizations/$organizationId/document'),
      builder: (context, snap) {
        if (!snap.hasData) return const Skeleton(height: 56);
        final r = snap.data!;
        if (!r.ok) {
          return _flag(context, 'Could not check the document: ${r.errorText}');
        }
        final d = Map<String, dynamic>.from(r.json as Map);
        return switch (d['status']) {
          'ok' => PrivateFileTile(
            label: 'Supporting document',
            url: '${d['url']}',
            contentType: '${d['content_type']}',
          ),
          'missing' => _flag(context, 'Supporting document missing'),
          'unreadable' => _flag(
            context,
            'Supporting document unreadable (the file is gone). Ask for a re-upload.',
          ),
          _ => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _flag(
                context,
                'Old link, not an uploaded file. Check it manually.',
              ),
              Gaps.v4,
              SelectableText(
                '${d['url']}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        };
      },
    );
  }

  Widget _flag(BuildContext context, String text) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(Icons.flag_outlined, color: cs.error, size: 20),
        Gaps.h8,
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: cs.error),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// UC-B2 / manuscript 7.6 Barangay Receiving dashboard (assigned barangay)
// ---------------------------------------------------------------------------
/// 9.7: the donations behind a Barangay dashboard card. [empty] says, in
/// plain words, what will show here and when.
void _openBarangayDonations(
  BuildContext context,
  String title,
  List<Map> donations, {
  required IconData icon,
  required String empty,
}) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: donations.isEmpty
            ? Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: EmptyView(
                    icon: icon,
                    title: 'Nothing here yet',
                    message: empty,
                  ),
                ),
              )
            : _BarangayDonationList(donations: donations),
      ),
    ),
  );
}

class _BarangayDonationList extends StatelessWidget {
  final List<Map> donations;
  const _BarangayDonationList({required this.donations});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: Breakpoints.contentMax),
        child: ListView(
          padding: Space.page,
          children: [
            Text(
              '${donations.length} '
              '${donations.length == 1 ? 'donation' : 'donations'}',
              style: t.titleMedium,
            ),
            Gaps.v12,
            for (final d in donations) ...[
              AppCard(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: cs.primaryContainer,
                      child: Icon(
                        Icons.inventory_2_outlined,
                        size: 20,
                        color: cs.onPrimaryContainer,
                      ),
                    ),
                    Gaps.h12,
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // G-002 (D8): readable amount and packaging.
                          Text(
                            '${d['item_name']} · ${itemAmount(d)}'
                            '${(d['packaging'] ?? '').toString().isEmpty ? '' : ' (${d['packaging']})'}',
                            style: t.titleSmall,
                          ),
                          Gaps.v4,
                          Text(
                            '${d['report_label']}',
                            style: t.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                          Text(
                            '${d['qr_reference']}',
                            style: t.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Gaps.h8,
                    StatusChip('${d['status']}'),
                  ],
                ),
              ),
              Gaps.v12,
            ],
          ],
        ),
      ),
    );
  }
}

class BarangayDashboard extends StatelessWidget {
  const BarangayDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [() => api.get('/dashboard/barangay')],
      builder: (context, data) {
        final m = data[0] as Map;
        final reports = (m['reports'] as List).cast<Map>();
        final donations = (m['donations'] as List).cast<Map>();
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            PageHeader(
              'Barangay ${m['barangay'] ?? ''} Dashboard',
              subtitle: roleLine(),
            ),
            // 9.7 (testing): each card opens the donations behind it; Aid
            // acknowledged goes to the Incoming aid tab.
            StatGrid([
              StatTile(
                'Donations linked to our reports',
                '${m['donations_linked']}',
                Icons.volunteer_activism_outlined,
                onTap: () => _openBarangayDonations(
                  context,
                  'Donations linked to our reports',
                  donations,
                  icon: Icons.volunteer_activism_outlined,
                  empty:
                      "When donors give to your barangay's reports, their "
                      'donations show here.',
                ),
              ),
              StatTile(
                'Waiting for CMO acknowledgement',
                '${m['pending_city_confirmation']}',
                Icons.hourglass_top,
                color: const Color(0xFFEF6C00),
                onTap: () => _openBarangayDonations(
                  context,
                  'Waiting for CMO acknowledgement',
                  donations.where((d) => d['status'] == 'Received').toList(),
                  icon: Icons.hourglass_top,
                  empty:
                      'Donations that CSWS received for your barangay show '
                      "here until the City Mayor's Office acknowledges them.",
                ),
              ),
              StatTile(
                'Acknowledged by CMO',
                '${m['confirmed']}',
                Icons.verified_outlined,
                color: const Color(0xFF2E7D32),
                onTap: () => _openBarangayDonations(
                  context,
                  'Acknowledged by CMO',
                  donations.where((d) => d['status'] == 'Confirmed').toList(),
                  icon: Icons.verified_outlined,
                  empty:
                      "Donations the City Mayor's Office has acknowledged "
                      'show here.',
                ),
              ),
              StatTile(
                'Aid acknowledged',
                '${m['acknowledged']}',
                Icons.task_alt,
                onTap: () =>
                    HomeNav.go(context, const HomeTarget('Incoming aid')),
              ),
            ]),
            const SectionTitle('Fulfillment per report'),
            if (reports.isEmpty)
              const EmptyState('No reports for this barangay.'),
            for (final r in reports)
              Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${r['report_label']}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Badge2.status('${r['status']}'),
                        ],
                      ),
                      Text(
                        '${r['confirmed_donations']} donation(s) acknowledged by the CMO',
                      ),
                      const SizedBox(height: 8),
                      Progress(
                        delivered: r['total_items_delivered'] as num? ?? 0,
                        needed: r['total_items_needed'] as num? ?? 0,
                        percent: r['fulfillment_percentage'] as num?,
                      ),
                    ],
                  ),
                ),
              ),
            const SectionTitle('Donation references'),
            if (donations.isEmpty) const EmptyState('No donations yet.'),
            for (final d in donations)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  dense: true,
                  title: Text(
                    '${d['item_name']} · ${itemAmount(d)} · ${d['qr_reference']}',
                  ),
                  // G-002 (D8)
                  isThreeLine: true,
                  subtitle: Text('${itemQuantities(d)}\n${d['report_label']}'),
                  trailing: Badge2.status('${d['status']}'),
                ),
              ),
          ],
        );
      },
    );
  }
}
