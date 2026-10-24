import 'package:flutter/material.dart';

import '../api.dart';
import 'account_detail_screen.dart';
import 'account_form.dart' show AccountsScreen;
import 'csws_screens.dart' show ActivityList;
import 'donation_info.dart' show BarangayDonationInfoScreen;
import 'private_file_view.dart';
import 'widgets.dart';
import 'pending_items.dart';
import 'entry_report_views.dart';
import 'home_nav.dart';

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
            const PendingItemsCard(), // F-15

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
            onSelectionChanged: (s) => setState(() {
              view = s.first;
              _focus = null;
            }),
          ),
        ),
        Expanded(
          child: switch (view) {
            'registrations' => RegistrationsScreen(
              key: ValueKey('registrations-$_focusSeq'),
              focusType: _focus?.$1,
              focusId: _focus?.$2,
            ),
            'donation' => const BarangayDonationInfoScreen(),
            'new' => const AccountsScreen(),
            _ => UsersScreen(key: ValueKey('accounts-$status'), status: status),
          },
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
  int reloads = 0; // bumped after an account is deleted, so the list reloads

  /// For a deactivated account, a labeled line with the reason the
  /// Administrator gave (or a note when none was recorded).
  String _reasonLine(Map u) {
    if (u['is_active'] == true) return '';
    final r = '${u['deactivation_reason'] ?? ''}'.trim();
    return '\nDeactivated · Reason: ${r.isEmpty ? 'No reason was recorded' : r}';
  }

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [
        () => api.get(
          '/admin/users',
          query: {
            if (status != 'all') 'active': '${status == 'active'}',
            if (role.isNotEmpty) 'role': role,
            if (q.isNotEmpty) 'q': q,
          },
        ),
      ],
      key: ValueKey('$status|$role|$q|$reloads'),
      builder: (context, data) {
        final users = (data[0] as List).cast<Map>();
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
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
              onSubmitted: (v) => setState(() => q = v.trim()),
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
                      const DropdownMenuItem(
                        value: '',
                        child: Text('All roles'),
                      ),
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
                    onChanged: (v) => setState(() => role = v ?? ''),
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
                    onChanged: (v) => setState(() => status = v ?? 'all'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '${users.length} ${status == 'all' ? '' : '$status '}accounts',
              style: const TextStyle(color: Brand.muted),
            ),
            const SizedBox(height: 6),
            for (final u in users)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: u['is_active'] == true
                        ? Brand.pinkSoft
                        : Colors.black12,
                    child: Icon(
                      u['is_active'] == true
                          ? Icons.person
                          : Icons.person_off_outlined,
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
                    if (deleted == true && mounted) setState(() => reloads++);
                  },
                  // UC-A1: tap the row for details, Edit details and
                  // Deactivate (account_detail_screen.dart).
                  trailing: const Icon(Icons.chevron_right),
                ),
              ),
          ],
        );
      },
    );
  }
}

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
  bool _focused = false;
  final _focusKey = GlobalKey();
  String kind = 'all'; // all | donors | orgs
  String sort = 'newest'; // newest | oldest | name
  String search = '';
  final Set<String> _busy = {};
  int _loads = 0;

  DateTime? _when(dynamic v) =>
      v == null ? null : DateTime.tryParse('$v')?.toLocal();

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
    setState(() {
      _busy.remove(key);
      if (r.ok) _loads++;
    });
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

  @override
  Widget build(BuildContext context) {
    return Loader(
      key: ValueKey(_loads),
      load: [
        () => api.get('/admin/organizations'),
        () => api.get('/admin/users', query: {'role': Roles.donor}),
      ],
      builder: (context, data) {
        final all = <Map<String, dynamic>>[
          for (final o in (data[0] as List).cast<Map>())
            {
              'type': 'org',
              'id': o['organization_id'],
              'name': '${o['org_name']}',
              'email': '${o['contact_email'] ?? 'No email'}',
              'when': _when(o['created_at']),
              'reviewed': o['reviewed_at'] != null,
              'org': o,
            },
          for (final u in (data[1] as List).cast<Map>())
            {
              'type': 'donor',
              'id': u['user_id'],
              'name': '${u['name']}',
              'email': '${u['email']}',
              'when': _when(u['created_at']),
              'reviewed': u['reviewed_at'] != null,
            },
        ];
        // Open on the notified account: its type and review section.
        final focus = widget.focusId == null
            ? null
            : all
                  .where(
                    (i) =>
                        i['type'] == widget.focusType &&
                        i['id'] == widget.focusId,
                  )
                  .firstOrNull;
        if (focus != null && !_focused) {
          _focused = true;
          review = focus['reviewed'] == true ? 'done' : 'not';
          kind = focus['type'] == 'org' ? 'orgs' : 'donors';
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final c = _focusKey.currentContext;
            if (c != null) Scrollable.ensureVisible(c, alignment: 0.1);
          });
        }
        final notReviewed = all.where((i) => i['reviewed'] != true).length;
        final q = search.trim().toLowerCase();
        final items = all
            .where(
              (i) =>
                  review == 'all' ||
                  (review == 'done') == (i['reviewed'] == true),
            )
            .where(
              (i) => kind == 'all' || (kind == 'orgs') == (i['type'] == 'org'),
            )
            .where(
              (i) =>
                  q.isEmpty ||
                  '${i['name']} ${i['email']}'.toLowerCase().contains(q),
            )
            .toList();

        int byDate(Map a, Map b) {
          final x = a['when'] as DateTime?;
          final y = b['when'] as DateTime?;
          if (x == null && y == null) return 0;
          if (x == null) return 1;
          if (y == null) return -1;
          return x.compareTo(y);
        }

        items.sort(
          (a, b) => switch (sort) {
            'oldest' => byDate(a, b),
            'name' => (a['name'] as String).toLowerCase().compareTo(
              (b['name'] as String).toLowerCase(),
            ),
            _ => byDate(b, a),
          },
        );

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const PageHeader(
              'Registrations',
              subtitle:
                  'Individual donors and organizations. Their accounts are '
                  'active as soon as they register; review each one here.',
            ),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: 'all', label: Text('All (${all.length})')),
                ButtonSegment(
                  value: 'done',
                  label: Text('Reviewed (${all.length - notReviewed})'),
                ),
                ButtonSegment(
                  value: 'not',
                  label: Text('Not Reviewed ($notReviewed)'),
                ),
              ],
              selected: {review},
              onSelectionChanged: (s) => setState(() => review = s.first),
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
                    onSelected: (_) => setState(() => kind = value),
                  ),
              ],
            ),
            Gaps.v12,
            AppTextField(
              label: 'Search name or email',
              icon: Icons.search,
              onChanged: (v) => setState(() => search = v),
            ),
            Gaps.v12,
            DropdownButtonFormField<String>(
              initialValue: sort,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Sort by'),
              items: const [
                DropdownMenuItem(value: 'newest', child: Text('Newest first')),
                DropdownMenuItem(value: 'oldest', child: Text('Oldest first')),
                DropdownMenuItem(value: 'name', child: Text('Name (A to Z)')),
              ],
              onChanged: (v) => setState(() => sort = v ?? 'newest'),
            ),
            Gaps.v16,
            if (items.isEmpty)
              EmptyState(
                review == 'not'
                    ? 'Every registration has been reviewed.'
                    : 'No registrations to show.',
              ),
            for (final i in items)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.sm),
                child: _RegistrationCard(
                  key: identical(i, focus) ? _focusKey : null,
                  highlighted: identical(i, focus),
                  item: i,
                  busy: _busy.contains('${i['type']}-${i['id']}'),
                  onReview: (v) => _setReviewed(i, v),
                ),
              ),
          ],
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
  const _RegistrationCard({
    super.key,
    required this.item,
    required this.busy,
    required this.onReview,
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
                          ? '${o?['organization_type'] ?? 'Organization'}'
                          : 'Individual donor',
                      style: muted,
                    ),
                  ],
                ),
              ),
              Gaps.h8,
              StatusChip(reviewed ? 'Reviewed' : 'Not Reviewed'),
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
                          Text(
                            '${d['quantity']} ${d['item_name']}',
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
                    '${d['quantity']} ${d['item_name']} · ${d['qr_reference']}',
                  ),
                  subtitle: Text('${d['report_label']}'),
                  trailing: Badge2.status('${d['status']}'),
                ),
              ),
          ],
        );
      },
    );
  }
}
