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

// ---------------------------------------------------------------------------
// UC-A4 / manuscript 7.7 Administrator dashboard
// ---------------------------------------------------------------------------
class AdminDashboard extends StatelessWidget {
  const AdminDashboard({super.key});

  /// 5.1: open the details behind a tile on its own page with a back arrow.
  void _open(BuildContext context, String title, Widget child) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: child,
        ),
      ),
    );
  }

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
                onTap: () => _open(
                  context,
                  'Active accounts',
                  const UsersScreen(key: ValueKey('active')),
                ),
              ),
              // The Administrator now only reviews organizations (accounts
              // activate automatically), so this says "review", not "approve".
              StatTile(
                'Organizations to review',
                '${m['pending_organizations']}',
                Icons.apartment_outlined,
                color: const Color(0xFFEF6C00),
                onTap: () => _open(
                  context,
                  'Organizations',
                  const OrganizationsReview(),
                ),
              ),
              StatTile(
                'Reports to validate',
                '${m['pending_validations']}',
                Icons.fact_check_outlined,
                color: const Color(0xFFEF6C00),
                onTap: () => _open(
                  context,
                  'Reports to validate',
                  const DashboardReportsList(status: 'Pending'),
                ),
              ),
              StatTile(
                'Validated reports',
                '${m['validated_reports']}',
                Icons.verified_outlined,
                color: const Color(0xFF2E7D32),
                onTap: () => _open(
                  context,
                  'Validated reports',
                  const DashboardReportsList(status: 'Validated'),
                ),
              ),
              // Team rule: count ENTRIES (one per donor submission), not rows.
              StatTile(
                'Donation entries',
                '${entries['total_entries']}',
                Icons.volunteer_activism_outlined,
                note: '${m['total_donations']} items · tap to view',
                onTap: () =>
                    openDonationEntries(context, title: 'All donation entries'),
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

/// 5.1: the reports behind a dashboard number, filtered by status.
class DashboardReportsList extends StatelessWidget {
  final String status;
  const DashboardReportsList({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [
        () => api.get('/dashboard/admin/reports', query: {'status': status}),
      ],
      builder: (context, data) {
        final reports = (data[0] as List).cast<Map>();
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              '${reports.length} ${status.toLowerCase()} report(s)',
              style: const TextStyle(color: Brand.muted),
            ),
            const SizedBox(height: 8),
            if (reports.isEmpty)
              EmptyState('No ${status.toLowerCase()} reports.'),
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
                              '${r['report_label'] ?? 'Report #${r['report_id']}'}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Badge2.status('${r['status']}'),
                        ],
                      ),
                      Text('Priority: ${r['priority_level'] ?? '-'}'),
                      if (status != 'Pending') ...[
                        const SizedBox(height: 8),
                        Progress(
                          delivered: 0,
                          needed: 0,
                          percent: r['fulfillment_percentage'] as num,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
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
  /// active, deactivated, registrations, orgs, donation, new.
  final String initialView;
  const AccountsHub({super.key, this.initialView = 'active'});

  @override
  State<AccountsHub> createState() => _AccountsHubState();
}

class _AccountsHubState extends State<AccountsHub> {
  late String view = widget.initialView;

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
              // New organizations and individual donors in one sortable list.
              ButtonSegment(
                value: 'registrations',
                label: Text('Registrations'),
              ),
              ButtonSegment(value: 'orgs', label: Text('Organizations')),
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
            'orgs' => const OrganizationsReview(),
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

/// New registrations: organizations and individual donors in one list,
/// with a type filter and sorting. Tapping an organization opens the
/// Organizations review (Reviewed / Not Reviewed); tapping a donor opens
/// the account details.
class RegistrationsScreen extends StatefulWidget {
  const RegistrationsScreen({super.key});

  @override
  State<RegistrationsScreen> createState() => _RegistrationsScreenState();
}

class _RegistrationsScreenState extends State<RegistrationsScreen> {
  String kind = 'all'; // all | orgs | donors
  String sort = 'newest'; // newest | oldest | name

  DateTime? _when(dynamic v) =>
      v == null ? null : DateTime.tryParse('$v')?.toLocal();

  String _fmt(DateTime? d) {
    if (d == null) return 'Unknown date';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [
        () => api.get('/admin/organizations'),
        () => api.get('/admin/users', query: {'role': Roles.donor}),
      ],
      builder: (context, data) {
        final orgs = (data[0] as List).cast<Map>();
        final donors = (data[1] as List).cast<Map>();

        final items = <Map<String, dynamic>>[
          if (kind != 'donors')
            for (final o in orgs)
              {
                'type': 'org',
                'name': '${o['org_name']}',
                'when': _when(o['created_at']),
                'detail':
                    '${o['organization_type'] ?? 'Organization'}'
                    ' · ${o['contact_email'] ?? 'No email'}',
                'reviewed': o['reviewed_at'] != null,
              },
          if (kind != 'orgs')
            for (final u in donors)
              {
                'type': 'donor',
                'user_id': u['user_id'],
                'name': '${u['name']}',
                'when': _when(u['created_at']),
                'detail': 'Individual donor · ${u['email']}',
                'reviewed': null,
              },
        ];

        int byDate(Map a, Map b) {
          final x = a['when'] as DateTime?;
          final y = b['when'] as DateTime?;
          if (x == null && y == null) return 0;
          if (x == null) return 1;
          if (y == null) return -1;
          return x.compareTo(y);
        }

        items.sort((a, b) {
          switch (sort) {
            case 'oldest':
              return byDate(a, b);
            case 'name':
              return (a['name'] as String).toLowerCase().compareTo(
                (b['name'] as String).toLowerCase(),
              );
            default:
              return byDate(b, a);
          }
        });

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const PageHeader(
              'New registrations',
              subtitle: 'Organizations and individual donors together. Tap an organization to review it.',
            ),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'all', label: Text('All')),
                ButtonSegment(value: 'orgs', label: Text('Organizations')),
                ButtonSegment(value: 'donors', label: Text('Donors')),
              ],
              selected: {kind},
              onSelectionChanged: (s) => setState(() => kind = s.first),
            ),
            const SizedBox(height: 10),
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
            const SizedBox(height: 12),
            Text(
              '${items.length} registrations',
              style: const TextStyle(color: Brand.muted),
            ),
            const SizedBox(height: 6),
            if (items.isEmpty) const EmptyState('No registrations yet.'),
            for (final i in items)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Icon(
                    i['type'] == 'org'
                        ? Icons.apartment_outlined
                        : Icons.person_outline,
                  ),
                  title: Text('${i['name']}'),
                  subtitle: Text(
                    '${i['detail']}\nRegistered ${_fmt(i['when'])}',
                  ),
                  isThreeLine: true,
                  trailing: i['reviewed'] == null
                      ? const Icon(Icons.chevron_right)
                      : Badge2.status(
                          i['reviewed'] == true ? 'Reviewed' : 'Not Reviewed',
                        ),
                  onTap: () {
                    if (i['type'] == 'org') {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => Scaffold(
                            appBar: AppBar(title: const Text('Organizations')),
                            body: const OrganizationsReview(),
                          ),
                        ),
                      );
                    } else if (i['user_id'] is int) {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              AccountDetailScreen(userId: i['user_id'] as int),
                        ),
                      );
                    }
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}

class OrganizationsReview extends StatefulWidget {
  const OrganizationsReview({super.key});

  @override
  State<OrganizationsReview> createState() => _OrganizationsReviewState();
}

class _OrganizationsReviewState extends State<OrganizationsReview> {
  bool reviewed = false;
  final Set<int> busyIds = {};

  Future<void> _setReviewed(int organizationId, bool value) async {
    if (busyIds.contains(organizationId)) return;
    setState(() => busyIds.add(organizationId));

    final result = await api.patch(
      '/admin/organizations/$organizationId/review',
      body: {'reviewed': value},
    );

    if (!mounted) return;

    setState(() => busyIds.remove(organizationId));

    if (!result.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update review: ${result.errorText}')),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          value
              ? 'Organization marked Reviewed.'
              : 'Organization marked Not Reviewed.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Loader(
      key: ValueKey(reviewed),
      load: [
        () => api.get(
          '/admin/organizations',
          query: {'reviewed': reviewed ? 'true' : 'false'},
        ),
      ],
      builder: (context, data) {
        final orgs = (data[0] as List).cast<Map>();
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const PageHeader(
              'Organization Registrations',
              subtitle: 'Organizations activate automatically. Review records here without changing account access.',
            ),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Not Reviewed')),
                ButtonSegment(value: true, label: Text('Reviewed')),
              ],
              selected: {reviewed},
              onSelectionChanged: (selection) {
                setState(() => reviewed = selection.first);
              },
            ),
            const SizedBox(height: 12),
            if (orgs.isEmpty)
              EmptyState(
                reviewed
                    ? 'No reviewed organizations.'
                    : 'No organizations waiting for review.',
              ),
            for (final o in orgs)
              Builder(
                builder: (context) {
                  final id = o['organization_id'] as int;
                  final isReviewed = o['reviewed_at'] != null;
                  final busy = busyIds.contains(id);

                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${o['org_name']}',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Badge2.status(
                                isReviewed ? 'Reviewed' : 'Not Reviewed',
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text('${o['organization_type'] ?? 'Organization'}'),
                          Text(
                            'Registration no.: ${o['registration_no'] ?? 'Not provided'}',
                          ),
                          if ((o['address'] ?? '').toString().trim().isNotEmpty)
                            Text('Address: ${o['address']}'),
                          Text(
                            'Contact: ${o['contact_person'] ?? 'Not provided'}',
                          ),
                          Text(
                            'Email: ${o['contact_email'] ?? 'Not provided'}',
                          ),
                          if (o['created_at'] != null)
                            Text('Registered: ${o['created_at']}'),
                          const SizedBox(height: 12),
                          _OrgDocument(id),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: busy
                                  ? null
                                  : () => _setReviewed(id, !isReviewed),
                              icon: busy
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Icon(
                                      isReviewed
                                          ? Icons.mark_email_unread_outlined
                                          : Icons.fact_check_outlined,
                                    ),
                              label: Text(
                                isReviewed
                                    ? 'Mark Not Reviewed'
                                    : 'Mark Reviewed',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
          ],
        );
      },
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
                'Pending city confirmation',
                '${m['pending_city_confirmation']}',
                Icons.hourglass_top,
                color: const Color(0xFFEF6C00),
              ),
              StatTile(
                'Confirmed by the City',
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
                        '${r['confirmed_donations']} city-confirmed donation(s)',
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
