import 'package:flutter/material.dart';

import 'api.dart';
import 'common.dart';
import 'report_api.dart';
import 'report_list_screen.dart';

/// One feature screen and the roles that are meant to use it.
/// `guest: true` means it also works without logging in.
class Module {
  final String title;
  final String code; // manuscript module number
  final IconData icon;
  final Set<String> roles;
  final bool guest;
  final WidgetBuilder builder;
  const Module(
    this.title,
    this.code,
    this.icon,
    this.roles,
    this.builder, {
    this.guest = false,
  });

  bool isFor(Api api) => api.loggedIn ? roles.contains(api.role) : guest;
}

// Screens and roles follow the manuscript's use cases (Tables 7-29).
final modules = <Module>[
  Module(
    'Support a report (donate)',
    'UC-D2 / UC-R2',
    Icons.volunteer_activism_outlined,
    {Roles.donor, Roles.org},
    (_) => const DonatePage(),
    guest: true,
  ),
  Module('Submit post-disaster report', 'UC-CD1', Icons.edit_note_outlined, {
    Roles.cswsUnit,
  }, (_) => const SubmitReportPage()),
  Module('Process reports', 'UC-A3', Icons.fact_check_outlined, {
    Roles.admin,
  }, (_) => const ProcessReportsPage()),
  Module('Needs monitoring', 'UC-CD2', Icons.monitor_heart_outlined, {
    Roles.cswsUnit,
    Roles.admin,
  }, (_) => const MonitoringPage()),
  Module('Handle physical donations', 'UC-CM1', Icons.inventory_2_outlined, {
    Roles.cswsMain,
  }, (_) => const ReceivingPage()),
  Module(
    'Release & delivery tracking',
    'UC-CM2',
    Icons.local_shipping_outlined,
    {Roles.cswsMain},
    (_) => const DeliveriesPage(),
  ),
  Module(
    'Logistics support requests',
    'UC-CM2 3a / UC-DR1',
    Icons.fire_truck_outlined,
    {Roles.cswsMain, Roles.drrmo},
    (_) => const LogisticsPage(),
  ),
  Module(
    'City donation confirmation',
    'UC-C1 / UC-C2',
    Icons.verified_outlined,
    {Roles.cmo},
    (_) => const CmoPage(),
  ),
  Module('Receive & acknowledge aid', 'UC-B1', Icons.move_to_inbox_outlined, {
    Roles.barangay,
  }, (_) => const ReceiveAidPage()),
  Module('Dashboard', 'UC-A4 / CD2 / CM3 / B2', Icons.dashboard_outlined, {
    Roles.admin,
    Roles.cswsMain,
    Roles.cswsUnit,
    Roles.barangay,
  }, (_) => const DashboardPage()),
  Module(
    'Manage internal accounts',
    'UC-A1',
    Icons.admin_panel_settings_outlined,
    {Roles.admin},
    (_) => const AdminPage(),
  ),
  
    Module('Browse validated reports', '3.7 / 3.11', Icons.list_alt_outlined, {
    Roles.cswsUnit,
    Roles.admin,
  }, (_) => const ReportListScreen(api: ReportApi())),
];

final _api = Api.instance;

// ---------------------------------------------------------------------------
// 3.5 Donor / Relief Organization / guest
// ---------------------------------------------------------------------------
class DonatePage extends StatelessWidget {
  const DonatePage({super.key});

  @override
  Widget build(BuildContext context) {
    return ModulePage(
      title: 'Donate & QR code',
      note:
          'Logged in: the donation is linked to your account. '
          'Not logged in: fill in the guest fields. The report must exist '
          '(ideally Validated) and the item must exist in the items table.',
      children: [
        ApiForm(
          title: 'Submit a donation',
          subtitle: 'POST /donations/',
          fields: const [
            F(
              'report_id',
              'Validated report to support',
              lookup: 'validated_reports',
            ),
            F('item_id', 'Item', lookup: 'items'),
            F('packaging', 'Packaging', initial: 'Box'),
            F('quantity', 'Quantity', initial: '10', number: true),
            F('estimated_value', 'Estimated value (optional)', number: true),
            F(
              'handover_method',
              'Handover method',
              initial: 'Drop Off',
              options: ['Drop Off', 'Door to Door'],
            ),
            F('pickup_address', 'Pickup address (Door to Door only)'),
            F('guest_name', 'Guest full name (only if not logged in)'),
            F('guest_contact', 'Guest contact number (only if not logged in)'),
          ],
          button: 'Submit donation',
          onSubmit: (v) async {
            final body = <String, dynamic>{
              'report_id': v.i('report_id'),
              'item_id': v.i('item_id'),
              'packaging': v.s('packaging'),
              'quantity': v.i('quantity'),
              'estimated_value': v.d('estimated_value'),
              'handover_method': v.s('handover_method'),
              'pickup_address': v.s('pickup_address'),
            };
            if (!_api.loggedIn) {
              body['guest_donor'] = {
                'full_name': v.s('guest_name') ?? '',
                'contact_number': v.s('guest_contact') ?? '',
              };
            }
            final r = await _api.post('/donations/', body: body);
            if (!r.ok || r.json is! Map) return r;
            // Fetch and show the QR right away.
            final qr = await _api.get('/donations/${r.json['donation_id']}/qr');
            return qr.ok
                ? ApiResult(r.status, {
                    ...r.json as Map,
                    ...qr.json as Map,
                  }, r.raw)
                : r;
          },
          extra: qrImage,
        ),
        ApiForm(
          title: 'Show QR for a donation',
          subtitle: 'GET /donations/{id}/qr',
          fields: const [F('id', 'donation_id', number: true)],
          button: 'Get QR',
          onSubmit: (v) => _api.get('/donations/${v.i('id')}/qr'),
          extra: qrImage,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// UC-CD1 Submit post-disaster report (CSWS Disaster Unit)
// ---------------------------------------------------------------------------
class SubmitReportPage extends StatelessWidget {
  const SubmitReportPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ModulePage(
      title: 'Submit post-disaster report',
      note:
          'UC-CD1: the report is stored as Pending. It is not visible to '
          'donors until the Administrator validates it.',
      children: [
        ApiForm(
          title: 'New report',
          subtitle: 'POST /reports/',
          fields: const [
            F('disaster_type_id', 'Disaster type', lookup: 'disaster_types'),
            F('barangay_id', 'Barangay', lookup: 'barangays'),
            F('sitio_id', 'Sitio (optional)', lookup: 'sitios', optional: true),
            F('description', 'Short incident description'),
            F('affected_families', 'Affected families (DROMIC)', number: true),
            F('assistance_needed', 'Type of assistance needed'),
            F('estimated_quantity', 'Estimated quantity needed', number: true),
          ],
          button: 'Submit report',
          onSubmit: (v) => _api.post(
            '/reports/',
            body: {
              'disaster_type_id': v.i('disaster_type_id'),
              'barangay_id': v.i('barangay_id'),
              'sitio_id': v.i('sitio_id'),
              'description': v.s('description'),
              'affected_families': v.i('affected_families'),
              'assistance_needed': v.s('assistance_needed'),
              'estimated_quantity': v.i('estimated_quantity'),
              'source': 'Mobile',
            },
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// UC-A3 Process reports (Administrator)
// ---------------------------------------------------------------------------
class ProcessReportsPage extends StatelessWidget {
  const ProcessReportsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ModulePage(
      title: 'Process reports',
      note:
          'UC-A3: review pending reports, then validate (runs the AI-assisted '
          'priority guidance and publishes it to donors) or reject with a '
          'reason. SMS reports are encoded by the CSWS Disaster Unit '
          '(Appendix H 2.2), so the SMS form below is for that role.',
      children: [
        ApiForm(
          title: 'Pending reports',
          subtitle: 'GET /reports/?status=Pending',
          fields: const [
            F(
              'status',
              'Status',
              initial: 'Pending',
              options: ['Pending', 'Validated', 'Rejected', ''],
            ),
          ],
          button: 'List',
          onSubmit: (v) => _api.get(
            '/reports/',
            query: {if (v.s('status') != null) 'status': v.s('status')!},
          ),
        ),
        ApiForm(
          title: 'View report details',
          subtitle: 'GET /reports/{id}',
          fields: const [F('id', 'Report', lookup: 'reports')],
          button: 'View',
          onSubmit: (v) => _api.get('/reports/${v.i('id')}'),
        ),
        ApiForm(
          title: 'Validate',
          subtitle: 'POST /reports/{id}/validate',
          fields: const [F('id', 'Report', lookup: 'reports')],
          button: 'Validate',
          onSubmit: (v) => _api.post('/reports/${v.i('id')}/validate'),
        ),
        ApiForm(
          title: 'Reject',
          subtitle: 'POST /reports/{id}/reject',
          fields: const [
            F('id', 'Report', lookup: 'reports'),
            F('reason', 'Reason (sent back for correction)'),
          ],
          button: 'Reject',
          onSubmit: (v) => _api.post(
            '/reports/${v.i('id')}/reject',
            body: {'rejection_reason': v.s('reason')},
          ),
        ),
        ApiForm(
          title: 'Encode an SMS report',
          subtitle: 'POST /reports/sms',
          fields: const [
            F('contact_number', 'Sender contact number'),
            F('raw_message', 'SMS message as received'),
            F('disaster_type_id', 'Disaster type', lookup: 'disaster_types'),
            F('barangay_id', 'Barangay', lookup: 'barangays'),
            F('affected_families', 'Affected families', number: true),
            F('assistance_needed', 'Type of assistance needed'),
            F('estimated_quantity', 'Estimated quantity', number: true),
          ],
          button: 'Encode',
          onSubmit: (v) => _api.post(
            '/reports/sms',
            body: {
              'contact_number': v.s('contact_number'),
              'raw_message': v.s('raw_message'),
              'disaster_type_id': v.i('disaster_type_id'),
              'barangay_id': v.i('barangay_id'),
              'affected_families': v.i('affected_families'),
              'assistance_needed': v.s('assistance_needed'),
              'estimated_quantity': v.i('estimated_quantity'),
            },
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 3.7 Needs monitoring (CSWS Disaster Unit's main screen)
// ---------------------------------------------------------------------------
class MonitoringPage extends StatelessWidget {
  const MonitoringPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ModulePage(
      title: 'Needs monitoring',
      note:
          'Reports joined with their fulfillment progress. '
          'priority_level is set by the 3.11 scoring when a report is validated.',
      children: [
        ApiForm(
          title: 'Monitoring list',
          subtitle: 'GET /reports/monitoring',
          fields: const [
            F(
              'priority_level',
              'Priority filter',
              options: [
                '',
                'Critical',
                'High',
                'Medium',
                'Low',
                'Needs Review',
                'Review Required',
              ],
            ),
            F(
              'barangay_id',
              'Barangay filter',
              lookup: 'barangays',
              optional: true,
            ),
          ],
          button: 'Load',
          onSubmit: (v) => _api.get(
            '/reports/monitoring',
            query: {
              if (v.s('priority_level') != null)
                'priority_level': v.s('priority_level')!,
              if (v.s('barangay_id') != null)
                'barangay_id': v.s('barangay_id')!,
            },
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 3.6 CSWS Main Office receiving
// ---------------------------------------------------------------------------
class ReceivingPage extends StatelessWidget {
  const ReceivingPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ModulePage(
      title: 'Handle physical donations',
      note:
          'UC-CM1: find the pending donation (by its QR reference), record '
          'the actual quantity received, and inventory updates. Official '
          'confirmation is done by the CMO (UC-C1).',
      children: [
        ApiForm(
          title: 'Pending donations',
          subtitle: 'GET /donations/pending',
          button: 'Load',
          onSubmit: (_) => _api.get('/donations/pending'),
        ),
        ApiForm(
          title: 'Receive goods',
          subtitle: 'POST /donations/receive',
          fields: const [
            F('donation_id', 'Pending donation', lookup: 'pending_donations'),
            F('actual_quantity', 'Actual quantity received', number: true),
            F('notes', 'Notes (optional)'),
          ],
          button: 'Receive',
          onSubmit: (v) => _api.post(
            '/donations/receive',
            body: {
              'donation_id': v.i('donation_id'),
              'actual_quantity': v.i('actual_quantity'),
              'notes': v.s('notes'),
            },
          ),
        ),
        ApiForm(
          title: 'Inventory',
          subtitle: 'GET /donations/inventory',
          fields: const [
            F('report_id', 'Report filter', lookup: 'reports', optional: true),
          ],
          button: 'Load',
          onSubmit: (v) => _api.get(
            '/donations/inventory',
            query: {
              if (v.s('report_id') != null) 'report_id': v.s('report_id')!,
            },
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 3.8 CMO Representative
// ---------------------------------------------------------------------------
class CmoPage extends StatelessWidget {
  const CmoPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ModulePage(
      title: 'CMO donation confirmation',
      note:
          'The CMO sees donations CSWS has already Received and confirms '
          'them (or puts them On Hold / Pending Review).',
      children: [
        ApiForm(
          title: 'Donations waiting for CMO',
          subtitle: 'GET /cmo/donations/pending',
          button: 'Load',
          onSubmit: (_) => _api.get('/cmo/donations/pending'),
        ),
        ApiForm(
          title: 'Confirm a donation',
          subtitle: 'POST /cmo/donations/{id}/confirm',
          fields: const [
            F('id', 'Received donation', lookup: 'received_donations'),
            F(
              'status',
              'Decision',
              initial: 'Confirmed',
              options: ['Confirmed', 'On Hold', 'Pending Review'],
            ),
            F('notes', 'Notes (optional)'),
          ],
          button: 'Submit',
          onSubmit: (v) => _api.post(
            '/cmo/donations/${v.i('id')}/confirm',
            body: {'status': v.s('status'), 'notes': v.s('notes')},
          ),
        ),
        ApiForm(
          title: 'CMO dashboard',
          subtitle: 'GET /cmo/dashboard',
          button: 'Load',
          onSubmit: (_) => _api.get('/cmo/dashboard'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 3.9 Logistics: CSWS submits, DRRMO accepts / declines
// ---------------------------------------------------------------------------
class LogisticsPage extends StatelessWidget {
  const LogisticsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ModulePage(
      title: 'Logistics requests',
      note:
          'UC-CM2 3a / UC-DR1: CSWS asks DRRMO to transport a delivery it is '
          'preparing (create it first under Release & delivery tracking). '
          'DRRMO accepts with a schedule or declines with a reason.',
      children: [
        ApiForm(
          title: 'Submit logistics request (CSWS Main Office)',
          subtitle: 'POST /logistics/requests',
          fields: const [
            F(
              'delivery_id',
              'Delivery needing transport',
              lookup: 'open_deliveries',
            ),
            F('trucks', 'Trucks needed', initial: '1'),
            F('drivers', 'Drivers needed', initial: '1'),
            F('volunteers', 'Volunteers needed', initial: '0'),
          ],
          button: 'Submit request',
          onSubmit: (v) => _api.post(
            '/logistics/requests',
                       body: {
              'delivery_id': v.i('delivery_id'),
              'trucks': v.i('trucks'),
              'drivers': v.i('drivers'),
              'volunteers': v.i('volunteers'),
            },
          ),
        ),
        ApiForm(
          title: 'Pending requests (DRRMO)',
          subtitle: 'GET /drrmo/requests',
          button: 'Load', 
          onSubmit: (_) => _api.get('/drrmo/requests'),
        ),
        ApiForm(
          title: 'Accept & schedule (DRRMO)',
          subtitle: 'PATCH /drrmo/requests/{id}/accept',
          fields: [
            const F('id', 'Pending request', lookup: 'pending_requests'),
            F('scheduled_date', 'Scheduled date', initial: tomorrowIso()),
            const F('notes', 'Notes (optional)'),
          ],
          button: 'Accept',
          onSubmit: (v) => _api.patch(
            '/drrmo/requests/${v.i('id')}/accept',
            body: {
              'scheduled_date': v.s('scheduled_date'),
              'notes': v.s('notes'),
            },
          ),
        ),
        ApiForm(
          title: 'Decline (DRRMO)',
          subtitle: 'PATCH /drrmo/requests/{id}/decline',
          fields: const [
            F('id', 'Pending request', lookup: 'pending_requests'),
            F('notes', 'Reason (required)', initial: 'No vehicle available'),
          ],
          button: 'Decline',
          onSubmit: (v) => _api.patch(
            '/drrmo/requests/${v.i('id')}/decline',
            body: {'notes': v.s('notes')},
          ),
        ),
        ApiForm(
          title: 'DRRMO dashboard',
          subtitle: 'GET /drrmo/dashboard',
          button: 'Load',
          onSubmit: (_) => _api.get('/drrmo/dashboard'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// UC-CM2 Release & delivery tracking (CSWS Main Office)
// ---------------------------------------------------------------------------
class DeliveriesPage extends StatelessWidget {
  const DeliveriesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ModulePage(
      title: 'Release & delivery tracking',
      note:
          'UC-CM2: prepare goods for a validated report, then move the status '
          'one click at a time: Preparing -> In Transit -> Delivered. The '
          'Barangay Rep then acknowledges it (UC-B1). Need a truck? Use '
          'Logistics support requests.',
      children: [
        ApiForm(
          title: 'Prepare a delivery',
          subtitle: 'POST /deliveries/',
          fields: [
            const F(
              'report_id',
              'Validated report',
              lookup: 'validated_reports',
            ),
            const F(
              'destination_barangay_id',
              'Destination barangay',
              lookup: 'barangays',
            ),
            F('delivery_date', 'Delivery date', initial: tomorrowIso()),
            const F('item_id', 'Item', lookup: 'items'),
            const F('quantity', 'Quantity', initial: '10', number: true),
          ],
          button: 'Create delivery',
          onSubmit: (v) => _api.post(
            '/deliveries/',
            body: {
              'report_id': v.i('report_id'),
              'destination_barangay_id': v.i('destination_barangay_id'),
              'delivery_date': v.s('delivery_date'),
              'items': [
                {'item_id': v.i('item_id'), 'quantity': v.i('quantity')},
              ],
            },
          ),
        ),
        ApiForm(
          title: 'List deliveries',
          subtitle: 'GET /deliveries/',
          fields: const [
            F(
              'status',
              'Status filter',
              options: [
                '',
                'Preparing',
                'In Transit',
                'Delivered',
                'Confirmed',
              ],
            ),
          ],
          button: 'List',
          onSubmit: (v) => _api.get(
            '/deliveries/',
            query: {if (v.s('status') != null) 'status': v.s('status')!},
          ),
        ),
        ApiForm(
          title: 'Update tracking status',
          subtitle: 'POST /deliveries/{id}/advance',
          fields: const [F('id', 'Delivery', lookup: 'open_deliveries')],
          button: 'Move to next status',
          onSubmit: (v) => _api.post('/deliveries/${v.i('id')}/advance'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// UC-B1 Receive and acknowledge aid (Barangay Receiving Representative)
// ---------------------------------------------------------------------------
class ReceiveAidPage extends StatelessWidget {
  const ReceiveAidPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ModulePage(
      title: 'Receive & acknowledge aid',
      note:
          'UC-B1: when aid arrives, confirm receipt. This records the '
          'acknowledgment and updates the report\'s fulfillment progress.',
      children: [
        ApiForm(
          title: 'Deliveries to my barangay',
          subtitle: 'GET /deliveries/',
          button: 'Load',
          onSubmit: (_) => _api.get('/deliveries/'),
        ),
        ApiForm(
          title: 'Confirm receipt',
          subtitle: 'POST /deliveries/{id}/confirm-receipt',
          fields: const [
            F('id', 'Delivered aid', lookup: 'delivered_deliveries'),
            F('remarks', 'Remarks (optional)'),
          ],
          button: 'Confirm receipt',
          onSubmit: (v) => _api.post(
            '/deliveries/${v.i('id')}/confirm-receipt',
            body: {'remarks': v.s('remarks')},
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 3.12 Dashboard
// ---------------------------------------------------------------------------
class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ModulePage(
      title: 'Dashboard',
      children: [
        for (final p in const [
          'summary',
          'reports-breakdown',
          'fulfillment',
          'logistics',
        ])
          ApiForm(
            title: p,
            subtitle: 'GET /dashboard/$p',
            button: 'Load',
            onSubmit: (_) => _api.get('/dashboard/$p'),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 3.3 Admin-created internal accounts
// ---------------------------------------------------------------------------
class AdminPage extends StatelessWidget {
  const AdminPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ModulePage(
      title: 'Admin: staff accounts',
      children: [
        ApiForm(
          title: 'Create an internal account',
          subtitle: 'POST /admin/users   (Administrator)',
          fields: const [
            F('first_name', 'First name'),
            F('last_name', 'Last name'),
            F('email', 'Email'),
            F('password', 'Password (min 8)', obscure: true),
            F('contact_number', 'Contact number (min 7)'),
            F(
              'role_name',
              'Role',
              initial: Roles.cswsMain,
              options: [
                Roles.cswsUnit,
                Roles.cswsMain,
                Roles.cmo,
                Roles.drrmo,
                Roles.barangay,
              ],
            ),
            F(
              'assigned_barangay_id',
              'Assigned barangay (Barangay Rep only)',
              lookup: 'barangays',
              optional: true,
            ),
          ],
          button: 'Create account',
          onSubmit: (v) => _api.post(
            '/admin/users',
            body: {
              'first_name': v.s('first_name'),
              'last_name': v.s('last_name'),
              'email': v.s('email'),
              'password': v.raw['password'],
              'contact_number': v.s('contact_number'),
              'role_name': v.s('role_name'),
              'assigned_barangay_id': v.i('assigned_barangay_id'),
            },
          ),
        ),
      ],
    );
  }
}
