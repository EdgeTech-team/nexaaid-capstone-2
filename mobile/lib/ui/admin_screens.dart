import 'package:flutter/material.dart';

import '../api.dart';
import 'csws_screens.dart' show ActivityList;
import 'report_screens.dart' show AccountsScreen;
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
  String view = 'users';

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'users', label: Text('Accounts')),
              ButtonSegment(value: 'orgs', label: Text('Organizations')),
              ButtonSegment(value: 'new', label: Text('New account')),
            ],
            selected: {view},
            onSelectionChanged: (s) => setState(() => view = s.first),
          ),
        ),
        Expanded(
          child: switch (view) {
            'orgs' => const OrganizationsReview(),
            'new' => const AccountsScreen(),
            _ => const UsersScreen(),
          },
        ),
      ],
    );
  }
}

class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  String role = '';
  String q = '';

  Future<void> _toggle(Map u) async {
    final activate = u['is_active'] != true;
    await act(
      context,
      () => api.patch(
        '/admin/users/${u['user_id']}',
        body: {'is_active': activate},
      ),
      success: activate
          ? '${u['email']} activated'
          : '${u['email']} deactivated (can no longer log in)',
    );
  }

  Future<void> _edit(Map u, Names names) async {
    final brgys = names.rows('barangays');
    final isRep = u['role'] == Roles.barangay;
    final v = await formDialog(
      context,
      title: 'Edit ${u['email']}',
      fields: [
        DialogField(
          'contact',
          'Contact number',
          initial: '${u['contact_number']}',
        ),
        if (isRep && brgys.isNotEmpty)
          DialogField(
            'brgy',
            'Assigned barangay',
            initial: '${u['assigned_barangay'] ?? brgys.first['name']}',
            options: [for (final b in brgys) '${b['name']}'],
          ),
      ],
    );
    if (v == null || !mounted) return;
    int? brgyId;
    if (v['brgy'] != null) {
      brgyId = brgys.firstWhere((b) => b['name'] == v['brgy'])['id'] as int;
    }
    await act(
      context,
      () => api.patch(
        '/admin/users/${u['user_id']}',
        body: {'contact_number': v['contact'], 'assigned_barangay_id': ?brgyId},
      ),
      success: 'Account updated',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [
        () => api.get(
          '/admin/users',
          query: {if (role.isNotEmpty) 'role': role, if (q.isNotEmpty) 'q': q},
        ),
        api.lookupsResult,
      ],
      key: ValueKey('$role|$q'),
      builder: (context, data) {
        final users = (data[0] as List).cast<Map>();
        final names = Names(Map<String, dynamic>.from(data[1] as Map));
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const PageHeader(
              'User Management',
              subtitle: 'View accounts and roles, activate or deactivate them.',
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
              '${users.length} accounts',
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
                  trailing: PopupMenuButton<String>(
                    tooltip: 'Actions',
                    onSelected: (a) =>
                        a == 'toggle' ? _toggle(u) : _edit(u, names),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'toggle',
                        child: Text(
                          u['is_active'] == true ? 'Deactivate' : 'Activate',
                        ),
                      ),
                      const PopupMenuItem(value: 'edit', child: Text('Edit')),
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
                        '${o['organization_type']} · Reg. no. ${o['registration_no']}',
                      ),
                      Text('${o['address']}'),
                      Text(
                        'Contact: ${o['contact_person']} · ${o['contact_email']}',
                      ),
                      const SizedBox(height: 6),
                      if (o['document_missing'] == true)
                        const Badge2(
                          'Supporting document missing',
                          Color(0xFFC62828),
                          icon: Icons.flag_outlined,
                        )
                      else
                        SelectableText(
                          'Document: ${o['legitimacy_document_url']}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      const SizedBox(height: 8),
                      Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 8,
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

Widget _decisionButton(
  BuildContext context,
  Map o,
  String decision,
  String label,
) {
  void onPressed() => act(
    context,
    () => api.post(
      '/admin/organizations/${o['organization_id']}/decision',
      body: {'decision': decision},
    ),
    success: '${o['org_name']}: $decision',
  );
  return decision == 'Approved'
      ? FilledButton(onPressed: onPressed, child: Text(label))
      : OutlinedButton(onPressed: onPressed, child: Text(label));
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
