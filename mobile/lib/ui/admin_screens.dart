import 'package:flutter/material.dart';

import '../api.dart';
import 'account_detail_screen.dart';
import 'account_form.dart' show AccountsScreen;
import 'copyable_phone.dart';
import 'csws_screens.dart' show ActivityList;
import 'donation_info.dart' show BarangayDonationInfoScreen;
import 'private_file_view.dart';
import 'widgets.dart';
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
              StatTile(
                'Held donations',
                '${m['held_donations']}',
                Icons.pause_circle_outline,
                color: const Color(0xFFC62828),
                onTap: () => openHeldDonations(context),
              ),
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
  /// Which section to show first:
  /// active, deactivated, registrations (donors + organizations), donation, new.
  final String initialView;
  const AccountsHub({super.key, this.initialView = 'active'});

  @override
  State<AccountsHub> createState() => _AccountsHubState();
}

class _AccountsHubState extends State<AccountsHub>
    with HomeTargetListener<AccountsHub> {
  late String view = widget.initialView;

  // A registration notification opens Accounts > Registrations (home_nav).
  @override
  String get homeTab => 'Accounts';

  @override
  void applyHomeTarget(HomeTarget target) {
    if (target.view != null) {
      view = target.view == 'orgs' ? 'registrations' : target.view!;
    }
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
              ButtonSegment(value: 'active', label: Text('Active')),
              ButtonSegment(value: 'deactivated', label: Text('Deactivated')),
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
            onSelectionChanged: (s) => setState(() => view = s.first),
          ),
        ),
        Expanded(
          child: switch (view) {
            'registrations' => const RegistrationsScreen(),
            'donation' => const BarangayDonationInfoScreen(),
            'new' => const AccountsScreen(),
            'deactivated' => const UsersScreen(
              key: ValueKey('deactivated'),
              active: false,
            ),
            _ => const UsersScreen(key: ValueKey('active')),
          },
        ),
      ],
    );
  }
}

class UsersScreen extends StatefulWidget {
  /// I2: true = Active section, false = Deactivated section.
  final bool active;
  const UsersScreen({super.key, this.active = true});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  String role = '';
  String q = '';

  /// In the Deactivated section, a labeled line with the reason the
  /// Administrator gave (or a note when none was recorded).
  String _reasonLine(Map u) {
    if (widget.active) return '';
    final r = '${u['deactivation_reason'] ?? ''}'.trim();
    return '\nReason: ${r.isEmpty ? 'No reason was recorded' : r}';
  }

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [
        () => api.get(
          '/admin/users',
          query: {
            'active': '${widget.active}',
            if (role.isNotEmpty) 'role': role,
            if (q.isNotEmpty) 'q': q,
          },
        ),
      ],
      key: ValueKey('${widget.active}|$role|$q'),
      builder: (context, data) {
        final users = (data[0] as List).cast<Map>();
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            PageHeader(
              widget.active ? 'User Management' : 'Deactivated accounts',
              subtitle: widget.active
                  ? 'Tap an account to see its details, edit it, or deactivate it.'
                  : 'These accounts can\'t log in. Tap one to review it or activate it again.',
            ),
            TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                labelText: 'Search name or email',
              ),
              onSubmitted: (v) => setState(() => q = v.trim()),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
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
              onChanged: (v) => setState(() => role = v ?? ''),
            ),
            const SizedBox(height: 12),
            Text(
              '${users.length} ${widget.active ? 'active' : 'deactivated'} accounts',
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
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          AccountDetailScreen(userId: u['user_id'] as int),
                    ),
                  ),
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
  const RegistrationsScreen({super.key});

  @override
  State<RegistrationsScreen> createState() => _RegistrationsScreenState();
}

class _RegistrationsScreenState extends State<RegistrationsScreen> {
  String review = 'not'; // not | done | all
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
                ButtonSegment(
                  value: 'not',
                  label: Text('Not Reviewed ($notReviewed)'),
                ),
                ButtonSegment(
                  value: 'done',
                  label: Text('Reviewed (${all.length - notReviewed})'),
                ),
                const ButtonSegment(value: 'all', label: Text('All')),
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
  final ValueChanged<bool> onReview;
  const _RegistrationCard({
    required this.item,
    required this.busy,
    required this.onReview,
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
    return AppCard(
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
              if (!org)
                Expanded(
                  child: AppButton(
                    'View account',
                    icon: Icons.badge_outlined,
                    variant: AppButtonVariant.text,
                    expand: true,
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            AccountDetailScreen(userId: item['id'] as int),
                      ),
                    ),
                  ),
                ),
              if (!org) Gaps.h8,
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
// Appendix H 2.2: barangay reps see the CSWS Disaster Unit's phone number so
// they can send the emergency SMS report from their own phone. The number is
// copy-only: the app never opens the dialer or the SMS app.
// ---------------------------------------------------------------------------
class DisasterUnitContactCard extends StatefulWidget {
  const DisasterUnitContactCard({super.key});

  @override
  State<DisasterUnitContactCard> createState() =>
      _DisasterUnitContactCardState();
}

class _DisasterUnitContactCardState extends State<DisasterUnitContactCard> {
  late final Future<ApiResult> _future = api.get('/contacts/disaster-unit');

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return FutureBuilder<ApiResult>(
      future: _future,
      builder: (context, snap) {
        final res = snap.data;
        if (res == null || !res.ok || res.json is! List) {
          return const SizedBox.shrink();
        }
        final contacts = (res.json as List).cast<Map>();
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.sms_outlined, size: 18, color: cs.primary),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Emergency SMS report: CSWS Disaster Unit',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Tap the number to copy it, then send your report from your phone\'s messaging app.',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                ),
                const SizedBox(height: 8),
                if (contacts.isEmpty)
                  Text(
                    'No Disaster Unit contact number is available yet.',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                for (final c in contacts)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${c['name']}'),
                        CopyablePhone(
                          number: '${c['contact_number']}',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: cs.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// UC-B2 / manuscript 7.6 Barangay Receiving dashboard (assigned barangay)
// ---------------------------------------------------------------------------
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
            // Appendix H 2.2: Disaster Unit phone number for the emergency SMS.
            const DisasterUnitContactCard(),
            StatGrid([
              StatTile(
                'Donations linked to our reports',
                '${m['donations_linked']}',
                Icons.volunteer_activism_outlined,
              ),
              StatTile(
                'Waiting for CMO acknowledgement',
                '${m['pending_city_confirmation']}',
                Icons.hourglass_top,
                color: const Color(0xFFEF6C00),
              ),
              StatTile(
                'Acknowledged by CMO',
                '${m['confirmed']}',
                Icons.verified_outlined,
                color: const Color(0xFF2E7D32),
              ),
              StatTile(
                'Aid acknowledged',
                '${m['acknowledged']}',
                Icons.task_alt,
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
