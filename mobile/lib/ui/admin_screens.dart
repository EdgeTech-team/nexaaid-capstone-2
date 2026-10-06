import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import 'account_detail_screen.dart';
import 'account_form.dart' show AccountsScreen;
import 'csws_screens.dart' show ActivityList;
import 'donation_info.dart' show BarangayDonationInfoScreen;
import 'private_file_view.dart';
import 'widgets.dart';

// ---------------------------------------------------------------------------
// UC-A4 / manuscript 7.7 Administrator dashboard
// ---------------------------------------------------------------------------
class AdminDashboard extends StatelessWidget {
  const AdminDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [() => api.get('/dashboard/admin')],
      builder: (context, data) {
        final m = data[0] as Map;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            PageHeader('Administrator Dashboard', subtitle: roleLine()),
            StatGrid([
              StatTile(
                'Active users',
                '${m['active_users']} / ${m['total_users']}',
                Icons.people_outline,
              ),
              StatTile(
                'Organizations to approve',
                '${m['pending_organizations']}',
                Icons.apartment_outlined,
                color: const Color(0xFFEF6C00),
              ),
              StatTile(
                'Reports to validate',
                '${m['pending_validations']}',
                Icons.fact_check_outlined,
                color: const Color(0xFFEF6C00),
              ),
              StatTile(
                'Validated reports',
                '${m['validated_reports']}',
                Icons.verified_outlined,
                color: const Color(0xFF2E7D32),
              ),
              StatTile(
                'Donations tracked',
                '${m['total_donations']}',
                Icons.volunteer_activism_outlined,
              ),
              StatTile(
                'Held donations',
                '${m['held_donations']}',
                Icons.pause_circle_outline,
                color: const Color(0xFFC62828),
              ),
            ]),
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
  const AccountsHub({super.key});

  @override
  State<AccountsHub> createState() => _AccountsHubState();
}

class _AccountsHubState extends State<AccountsHub> {
  String view = 'active';

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
                    '${u['organization'] != null ? ' · ${u['organization']} (${u['organization_status']})' : ''}',
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

class OrganizationsReview extends StatefulWidget {
  const OrganizationsReview({super.key});

  @override
  State<OrganizationsReview> createState() => _OrganizationsReviewState();
}

class _OrganizationsReviewState extends State<OrganizationsReview> {
  String status = 'Pending';

  @override
  Widget build(BuildContext context) {
    return Loader(
      key: ValueKey(status),
      load: [
        () => api.get('/admin/organizations', query: {'status': status}),
      ],
      builder: (context, data) {
        final orgs = (data[0] as List).cast<Map>();
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const PageHeader(
              'Organization Registrations',
              subtitle: 'Relief organizations can only log in after approval (UC-A2).',
            ),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'Pending', label: Text('Pending')),
                ButtonSegment(value: 'Approved', label: Text('Approved')),
                ButtonSegment(value: 'Rejected', label: Text('Rejected')),
              ],
              selected: {status},
              onSelectionChanged: (s) => setState(() => status = s.first),
            ),
            // I3: the organization sees the same reason at login (D6).
            if (status == 'Rejected') ...[
              Gaps.v8,
              Text(
                'Rejected organizations see this reason when they try to log in.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 12),
            if (orgs.isEmpty)
              EmptyState('No ${status.toLowerCase()} organizations.'),
            for (final o in orgs)
              Card(
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
                            o['status'] == 'Approved'
                                ? 'Validated'
                                : '${o['status']}',
                          ),
                        ],
                      ),
                      Text(
                        '${o['organization_type']} · Reg. no. ${o['registration_no'] ?? 'not given'}',
                      ),
                      Text('${o['address']}'),
                      Text(
                        'Contact: ${o['contact_person']} · ${o['contact_email']}',
                      ),
                      Gaps.v12,
                      // UC-A2 step 4: the supporting document; alt 4a flags.
                      _OrgDocument(o['organization_id'] as int),
                      if (o['status'] == 'Rejected') ...[
                        Gaps.v8,
                        _RejectionReason(
                          reason: o['rejection_reason'] ?? o['decision_reason'],
                          at: o['decided_at'],
                        ),
                      ] else if (o['decision_reason'] != null) ...[
                        Gaps.v8,
                        Text(
                          'Last reason: ${o['decision_reason']}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      const SizedBox(height: 8),
                      Wrap(
                        alignment: WrapAlignment.end,
                        spacing: Space.xs,
                        runSpacing: Space.xs,
                        children: [
                          for (final d in const [
                            ['Rejected', 'Reject'],
                            ['Pending', 'Hold'],
                            ['Approved', 'Approve'],
                          ])
                            if (o['status'] != d[0])
                              _decisionButton(context, o, d[0], d[1]),
                        ],
                      ),
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

/// I3: why an organization was rejected. The organization sees the same
/// reason when it tries to log in (D6).
class _RejectionReason extends StatelessWidget {
  final dynamic reason;
  final dynamic at;
  const _RejectionReason({required this.reason, this.at});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            at == null ? 'Rejection reason' : 'Rejected ${niceDate(at)}',
            style: t.labelLarge?.copyWith(color: cs.onErrorContainer),
          ),
          Gaps.v8,
          Text(
            '${reason ?? 'No reason was recorded.'}',
            style: t.bodyMedium?.copyWith(color: cs.onErrorContainer),
          ),
        ],
      ),
    );
  }
}

/// Approve, Hold or Reject (UC-A2 steps 5-6). Hold and Reject ask for a
/// reason (alt 6a); the backend refuses them without one.
Widget _decisionButton(
  BuildContext context,
  Map o,
  String decision,
  String label,
) {
  Future<void> onPressed() async {
    String? reason;
    if (decision != 'Approved') {
      final v = await formDialog(
        context,
        title: '$label ${o['org_name']}?',
        message: decision == 'Rejected'
            ? 'The organization stays inactive. Say what is wrong so they can fix it.'
            : 'The application stays pending. Say what you are waiting for.',
        fields: const [DialogField('reason', 'Reason', multiline: true)],
        confirm: label,
      );
      if (v == null || !context.mounted) return;
      reason = v['reason'];
    }
    await act(
      context,
      () => api.post(
        '/admin/organizations/${o['organization_id']}/decision',
        body: {'decision': decision, 'reason': ?reason},
      ),
      success: '${o['org_name']}: $decision',
    );
  }

  return AppButton(
    label,
    onPressed: onPressed,
    variant: switch (decision) {
      'Approved' => AppButtonVariant.tonal,
      'Rejected' => AppButtonVariant.danger,
      _ => AppButtonVariant.secondary,
    },
  );
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
// they can send the emergency SMS report.
// ---------------------------------------------------------------------------
class DisasterUnitContactCard extends StatefulWidget {
  const DisasterUnitContactCard({super.key});

  @override
  State<DisasterUnitContactCard> createState() =>
      _DisasterUnitContactCardState();
}

class _DisasterUnitContactCardState extends State<DisasterUnitContactCard> {
  late final Future<ApiResult> _future = api.get('/contacts/disaster-unit');

  Future<void> _open(String scheme, String number) async {
    final ok = await launchUrl(Uri(scheme: scheme, path: number));
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open $scheme for $number')),
      );
    }
  }

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
                const SizedBox(height: 8),
                if (contacts.isEmpty)
                  Text(
                    'No Disaster Unit contact number is available yet.',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                for (final c in contacts)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${c['name']}'),
                              SelectableText(
                                '${c['contact_number']}',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: cs.primary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Send SMS',
                          icon: const Icon(Icons.sms),
                          onPressed: () =>
                              _open('sms', '${c['contact_number']}'),
                        ),
                        IconButton(
                          tooltip: 'Call',
                          icon: const Icon(Icons.call),
                          onPressed: () =>
                              _open('tel', '${c['contact_number']}'),
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
