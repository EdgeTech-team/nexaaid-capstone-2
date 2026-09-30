import 'package:flutter/material.dart';

import 'api.dart';
import 'common.dart';

/// One feature screen and the roles that are meant to use it.
/// `guest: true` means it also works without logging in.
class Module {
  final String title;
  final String code; // manuscript module number
  final IconData icon;
  final Set<String> roles;
  final bool guest;
  final WidgetBuilder builder;
  const Module(this.title, this.code, this.icon, this.roles, this.builder,
      {this.guest = false});

  bool isFor(Api api) =>
      api.loggedIn ? roles.contains(api.role) : guest;
}

final modules = <Module>[
  Module('Donate & QR code', '3.5', Icons.volunteer_activism_outlined,
      {Roles.donor, Roles.org, Roles.admin}, (_) => const DonatePage(),
      guest: true),
  Module('Disaster reports', '3.4 / 3.11', Icons.report_outlined,
      {Roles.barangay, Roles.admin, Roles.cswsMain, Roles.cswsUnit},
      (_) => const ReportsPage()),
  Module('Needs monitoring', '3.7', Icons.monitor_heart_outlined,
      {Roles.cswsUnit, Roles.cswsMain, Roles.admin, Roles.barangay},
      (_) => const MonitoringPage()),
  Module('Receiving & inventory', '3.6', Icons.inventory_2_outlined,
      {Roles.cswsMain, Roles.admin}, (_) => const ReceivingPage()),
  Module('CMO donation confirmation', '3.8', Icons.verified_outlined,
      {Roles.cmo}, (_) => const CmoPage()),
  Module('Logistics requests', '3.9', Icons.local_shipping_outlined,
      {Roles.cswsMain, Roles.drrmo}, (_) => const LogisticsPage()),
  Module('Deliveries & receipt', '3.10', Icons.move_to_inbox_outlined,
      {Roles.cswsMain, Roles.admin, Roles.barangay},
      (_) => const DeliveriesPage()),
  Module('Dashboard', '3.12', Icons.dashboard_outlined,
      {Roles.admin, Roles.cswsMain, Roles.cswsUnit, Roles.barangay},
      (_) => const DashboardPage()),
  Module('Admin: staff accounts', '3.3', Icons.admin_panel_settings_outlined,
      {Roles.admin}, (_) => const AdminPage()),
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
      note: 'Logged in: the donation is linked to your account. '
          'Not logged in: fill in the guest fields. The report must exist '
          '(ideally Validated) and the item must exist in the items table.',
      children: [
        ApiForm(
          title: 'Submit a donation',
          subtitle: 'POST /donations/',
          fields: const [
            F('report_id', 'report_id', initial: '1', number: true),
            F('item_id', 'item_id (1 = Rice)', initial: '1', number: true),
            F('packaging', 'Packaging', initial: 'Box'),
            F('quantity', 'Quantity', initial: '10', number: true),
            F('estimated_value', 'Estimated value (optional)', number: true),
            F('handover_method', 'Handover method',
                initial: 'Drop Off', options: ['Drop Off', 'Door to Door']),
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
                ? ApiResult(r.status, {...r.json as Map, ...qr.json as Map},
                    r.raw)
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
// 3.4 Reports (Barangay submits, Admin validates / rejects, staff views)
// ---------------------------------------------------------------------------
class ReportsPage extends StatelessWidget {
  const ReportsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ModulePage(
      title: 'Disaster reports',
      note: 'Barangay Rep submits. Administrator validates (this creates the '
          'fulfillment record and runs the 3.11 priority scoring) or rejects. '
          'CSWS and Barangay can list and view.',
      children: [
        ApiForm(
          title: 'Submit a report',
          subtitle: 'POST /reports/   (any logged-in user)',
          fields: const [
            F('disaster_type_id', 'disaster_type_id (1 = Flood)',
                initial: '1', number: true),
            F('barangay_id', 'barangay_id', initial: '1', number: true),
            F('sitio_id', 'sitio_id (optional)', number: true),
            F('description', 'Description', initial: 'Test flood report'),
            F('affected_families', 'Affected families',
                initial: '40', number: true),
            F('assistance_needed', 'Assistance needed', initial: 'Rice'),
            F('estimated_quantity', 'Estimated quantity needed',
                initial: '100', number: true),
            F('source', 'Source', initial: 'mobile', options: ['web', 'mobile']),
          ],
          button: 'Submit report',
          onSubmit: (v) => _api.post('/reports/', body: {
            'disaster_type_id': v.i('disaster_type_id'),
            'barangay_id': v.i('barangay_id'),
            'sitio_id': v.i('sitio_id'),
            'description': v.s('description'),
            'affected_families': v.i('affected_families'),
            'assistance_needed': v.s('assistance_needed'),
            'estimated_quantity': v.i('estimated_quantity'),
            'source': v.s('source'),
          }),
        ),
        ApiForm(
          title: 'List reports',
          subtitle: 'GET /reports/   (CSWS, Admin, Barangay)',
          fields: const [
            F('status', 'Status filter (optional)', hint: 'Pending / Validated'),
          ],
          button: 'List',
          onSubmit: (v) => _api.get('/reports/', query: {
            if (v.s('status') != null) 'status': v.s('status')!,
          }),
        ),
        ApiForm(
          title: 'View one report',
          subtitle: 'GET /reports/{id}   (owner or staff)',
          fields: const [F('id', 'report_id', initial: '1', number: true)],
          button: 'View',
          onSubmit: (v) => _api.get('/reports/${v.i('id')}'),
        ),
        ApiForm(
          title: 'Validate a report',
          subtitle: 'POST /reports/{id}/validate   (Administrator)',
          fields: const [F('id', 'report_id', number: true)],
          button: 'Validate',
          onSubmit: (v) => _api.post('/reports/${v.i('id')}/validate'),
        ),
        ApiForm(
          title: 'Reject a report',
          subtitle: 'POST /reports/{id}/reject   (Administrator)',
          fields: const [
            F('id', 'report_id', number: true),
            F('reason', 'Rejection reason', initial: 'Incomplete details'),
          ],
          button: 'Reject',
          onSubmit: (v) => _api.post('/reports/${v.i('id')}/reject',
              body: {'rejection_reason': v.s('reason')}),
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
      note: 'Reports joined with their fulfillment progress. '
          'priority_level is set by the 3.11 scoring when a report is validated.',
      children: [
        ApiForm(
          title: 'Monitoring list',
          subtitle: 'GET /reports/monitoring',
          fields: const [
            F('priority_level', 'Priority filter (optional)',
                hint: 'High / Medium / Low / Needs Review'),
            F('barangay_id', 'barangay_id filter (optional)', number: true),
          ],
          button: 'Load',
          onSubmit: (v) => _api.get('/reports/monitoring', query: {
            if (v.s('priority_level') != null)
              'priority_level': v.s('priority_level')!,
            if (v.s('barangay_id') != null) 'barangay_id': v.s('barangay_id')!,
          }),
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
      title: 'Receiving & inventory',
      note: 'Flow: Pending -> Received (receive) -> Confirmed '
          '(confirm here, or by the CMO in 3.8).',
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
            F('donation_id', 'donation_id', number: true),
            F('actual_quantity', 'Actual quantity received', number: true),
            F('notes', 'Notes (optional)'),
          ],
          button: 'Receive',
          onSubmit: (v) => _api.post('/donations/receive', body: {
            'donation_id': v.i('donation_id'),
            'actual_quantity': v.i('actual_quantity'),
            'notes': v.s('notes'),
          }),
        ),
        ApiForm(
          title: 'Confirm a received donation',
          subtitle: 'POST /donations/{id}/confirm',
          fields: const [F('id', 'donation_id', number: true)],
          button: 'Confirm',
          onSubmit: (v) => _api.post('/donations/${v.i('id')}/confirm'),
        ),
        ApiForm(
          title: 'Inventory',
          subtitle: 'GET /donations/inventory',
          fields: const [
            F('report_id', 'report_id filter (optional)', number: true)
          ],
          button: 'Load',
          onSubmit: (v) => _api.get('/donations/inventory', query: {
            if (v.s('report_id') != null) 'report_id': v.s('report_id')!,
          }),
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
      note: 'The CMO sees donations CSWS has already Received and confirms '
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
            F('id', 'donation_id', number: true),
            F('status', 'Decision',
                initial: 'Confirmed',
                options: ['Confirmed', 'On Hold', 'Pending Review']),
            F('notes', 'Notes (optional)'),
          ],
          button: 'Submit',
          onSubmit: (v) => _api.post('/cmo/donations/${v.i('id')}/confirm',
              body: {'status': v.s('status'), 'notes': v.s('notes')}),
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
      note: 'CSWS Main Office submits a request (this also creates a '
          'delivery in Preparing). DRRMO Logistics Support accepts with a '
          'schedule or declines with a reason.',
      children: [
        ApiForm(
          title: 'Submit logistics request (CSWS Main Office)',
          subtitle: 'POST /logistics/requests',
          fields: [
            const F('report_id', 'report_id', initial: '1', number: true),
            const F('destination_barangay_id', 'destination_barangay_id',
                initial: '1', number: true),
            const F('destination_sitio_id', 'destination_sitio_id (optional)',
                number: true),
            F('delivery_date', 'Delivery date', initial: tomorrowIso()),
            const F('notes', 'Notes (optional)'),
          ],
          button: 'Submit request',
          onSubmit: (v) => _api.post('/logistics/requests', body: {
            'report_id': v.i('report_id'),
            'destination_barangay_id': v.i('destination_barangay_id'),
            'destination_sitio_id': v.i('destination_sitio_id'),
            'delivery_date': v.s('delivery_date'),
            'notes': v.s('notes'),
          }),
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
            const F('id', 'request_id', number: true),
            F('scheduled_date', 'Scheduled date', initial: tomorrowIso()),
            const F('notes', 'Notes (optional)'),
          ],
          button: 'Accept',
          onSubmit: (v) =>
              _api.patch('/drrmo/requests/${v.i('id')}/accept', body: {
            'scheduled_date': v.s('scheduled_date'),
            'notes': v.s('notes'),
          }),
        ),
        ApiForm(
          title: 'Decline (DRRMO)',
          subtitle: 'PATCH /drrmo/requests/{id}/decline',
          fields: const [
            F('id', 'request_id', number: true),
            F('notes', 'Reason (required)', initial: 'No vehicle available'),
          ],
          button: 'Decline',
          onSubmit: (v) => _api.patch('/drrmo/requests/${v.i('id')}/decline',
              body: {'notes': v.s('notes')}),
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
// 3.10 Deliveries: CSWS creates / advances, Barangay confirms receipt
// ---------------------------------------------------------------------------
class DeliveriesPage extends StatelessWidget {
  const DeliveriesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ModulePage(
      title: 'Deliveries & receipt',
      note: 'Preparing -> In Transit -> Delivered (CSWS "advance") -> '
          'Confirmed (Barangay confirms receipt, which updates the report\'s '
          'fulfillment %). The report must be Validated first.',
      children: [
        ApiForm(
          title: 'Create delivery (CSWS Main Office)',
          subtitle: 'POST /deliveries/',
          fields: [
            const F('report_id', 'report_id', initial: '1', number: true),
            const F('destination_barangay_id', 'destination_barangay_id',
                initial: '1', number: true),
            F('delivery_date', 'Delivery date', initial: tomorrowIso()),
            const F('item_id', 'item_id', initial: '1', number: true),
            const F('quantity', 'Quantity', initial: '10', number: true),
          ],
          button: 'Create delivery',
          onSubmit: (v) => _api.post('/deliveries/', body: {
            'report_id': v.i('report_id'),
            'destination_barangay_id': v.i('destination_barangay_id'),
            'delivery_date': v.s('delivery_date'),
            'items': [
              {'item_id': v.i('item_id'), 'quantity': v.i('quantity')}
            ],
          }),
        ),
        ApiForm(
          title: 'List deliveries',
          subtitle: 'GET /deliveries/',
          fields: const [
            F('status', 'Status filter (optional)',
                hint: 'Preparing / In Transit / Delivered / Confirmed'),
          ],
          button: 'List',
          onSubmit: (v) => _api.get('/deliveries/', query: {
            if (v.s('status') != null) 'status': v.s('status')!,
          }),
        ),
        ApiForm(
          title: 'Advance status (CSWS Main Office)',
          subtitle: 'POST /deliveries/{id}/advance',
          fields: const [F('id', 'delivery_id', number: true)],
          button: 'Advance one step',
          onSubmit: (v) => _api.post('/deliveries/${v.i('id')}/advance'),
        ),
        ApiForm(
          title: 'Confirm receipt (Barangay Receiving Rep)',
          subtitle: 'POST /deliveries/{id}/confirm-receipt',
          fields: const [
            F('id', 'delivery_id', number: true),
            F('remarks', 'Remarks (optional)', initial: 'Received complete'),
          ],
          button: 'Confirm receipt',
          onSubmit: (v) => _api.post('/deliveries/${v.i('id')}/confirm-receipt',
              body: {'remarks': v.s('remarks')}),
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
          'logistics'
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
            F('role_name', 'Role', initial: Roles.cswsMain, options: [
              Roles.cswsUnit,
              Roles.cswsMain,
              Roles.cmo,
              Roles.drrmo,
              Roles.barangay,
            ]),
            F('assigned_barangay_id',
                'assigned_barangay_id (required for Barangay Rep)',
                number: true),
          ],
          button: 'Create account',
          onSubmit: (v) => _api.post('/admin/users', body: {
            'first_name': v.s('first_name'),
            'last_name': v.s('last_name'),
            'email': v.s('email'),
            'password': v.raw['password'],
            'contact_number': v.s('contact_number'),
            'role_name': v.s('role_name'),
            'assigned_barangay_id': v.i('assigned_barangay_id'),
          }),
        ),
      ],
    );
  }
}
