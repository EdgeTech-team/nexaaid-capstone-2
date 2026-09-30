import 'package:flutter/material.dart';

import '../api.dart';
import 'widgets.dart';

/// Card for one disaster report (with fulfillment if available).
class ReportCard extends StatelessWidget {
  final Map<String, dynamic> r;
  final Names names;
  final List<Widget> actions;
  const ReportCard(this.r, this.names, {super.key, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    final type = names.of('disaster_types', r['disaster_type_id']);
    final brgy = names.of('barangays', r['barangay_id']);
    final hasFulfillment = r['total_items_needed'] != null;
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
                    '#${r['report_id']}  $type in $brgy',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Badge2.status(r['status'] as String?),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (r['priority_level'] != null)
                  Badge2.priority(r['priority_level'] as String?),
                Badge2(
                  'via ${r['source']}',
                  Colors.blueGrey,
                  icon: Icons.input,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              [
                if (r['affected_families'] != null)
                  '${r['affected_families']} families',
                if (r['assistance_needed'] != null)
                  'Needs: ${r['assistance_needed']}',
                if (r['estimated_quantity'] != null)
                  'Qty: ${r['estimated_quantity']}',
              ].join('  ·  '),
            ),
            if (r['description'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${r['description']}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (r['ai_recommendation'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.auto_awesome,
                      size: 16,
                      color: Colors.deepPurple,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'AI guidance: ${r['ai_recommendation']}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            if (r['rejection_reason'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Rejected: ${r['rejection_reason']}',
                  style: const TextStyle(color: Color(0xFFC62828)),
                ),
              ),
            if (hasFulfillment) ...[
              const SizedBox(height: 10),
              Progress(
                delivered: r['total_items_delivered'] as num? ?? 0,
                needed: r['total_items_needed'] as num? ?? 0,
                percent: num.tryParse('${r['fulfillment_percentage']}'),
              ),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  for (final a in actions)
                    Padding(padding: const EdgeInsets.only(left: 8), child: a),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// UC-CD1 Submit post-disaster report (CSWS Disaster Unit)
// ---------------------------------------------------------------------------
class NewReportScreen extends StatefulWidget {
  const NewReportScreen({super.key});

  @override
  State<NewReportScreen> createState() => _NewReportScreenState();
}

/// One line of the needs list: an item (or "Other"), how many, and the unit.
class _Need {
  String? itemId; // items.item_id, or _other
  final qty = TextEditingController();
  final otherName = TextEditingController();
  final otherUnit = TextEditingController();
}

const _other = 'other';

class _NewReportScreenState extends State<NewReportScreen> {
  final _form = GlobalKey<FormState>();
  String? typeId, brgyId, sitioId;
  final desc = TextEditingController();
  final families = TextEditingController();
  final needs = <_Need>[_Need()];
  bool busy = false;

  String _needName(_Need n, Names names) => n.itemId == _other
      ? n.otherName.text.trim()
      : names
            .of('items', n.itemId, fallback: '')
            .replaceAll(RegExp(r'\s*\(.*\)$'), '');

  String _needUnit(_Need n, Names names) {
    if (n.itemId == _other) return n.otherUnit.text.trim();
    for (final i in names.rows('items')) {
      if ('${i['id']}' == n.itemId) return '${i['unit'] ?? ''}';
    }
    return '';
  }

  Future<void> _submit(Names names) async {
    if (!_form.currentState!.validate()) return;
    setState(() => busy = true);
    // The report table has one text field for the needs and one total
    // quantity, so the list is stored as "Rice: 50 kg, Drinking Water: 20 gallons".
    final summary = needs
        .map(
          (n) =>
              '${_needName(n, names)}: ${n.qty.text.trim()} ${_needUnit(n, names)}'
                  .trim(),
        )
        .join(', ');
    final total = needs.fold<int>(
      0,
      (a, n) => a + int.parse(n.qty.text.trim()),
    );
    final r = await act(
      context,
      () => api.post(
        '/reports/',
        body: {
          'disaster_type_id': int.parse(typeId!),
          'barangay_id': int.parse(brgyId!),
          'sitio_id': (sitioId ?? '').isEmpty ? null : int.parse(sitioId!),
          'description': desc.text.trim(),
          'affected_families': int.parse(families.text.trim()),
          'assistance_needed': summary,
          'estimated_quantity': total,
          'source': 'Mobile',
        },
      ),
      success: 'Report submitted. It is now pending admin validation.',
    );
    if (!mounted) return;
    setState(() {
      busy = false;
      if (r.ok) {
        _form.currentState!.reset();
        desc.clear();
        families.clear();
        needs
          ..clear()
          ..add(_Need());
        typeId = brgyId = sitioId = null;
      }
    });
  }

  String? _num(String? v) => (int.tryParse(v?.trim() ?? '') ?? 0) > 0
      ? null
      : 'Enter a number above 0';

  Widget _needRow(int i, Names names) {
    final n = needs[i];
    final unit = _needUnit(n, names);
    return Card(
      key: ObjectKey(n),
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: n.itemId,
                    isExpanded: true,
                    decoration: InputDecoration(labelText: 'Need ${i + 1}'),
                    items: [
                      for (final it in names.rows('items'))
                        DropdownMenuItem(
                          value: '${it['id']}',
                          child: Text('${it['item_name'] ?? it['name']}'),
                        ),
                      const DropdownMenuItem(
                        value: _other,
                        child: Text('Other…'),
                      ),
                    ],
                    onChanged: (v) => setState(() => n.itemId = v),
                    validator: (v) => v == null ? 'Choose an item' : null,
                  ),
                ),
                if (needs.length > 1)
                  IconButton(
                    tooltip: 'Remove this need',
                    onPressed: () => setState(() => needs.removeAt(i)),
                    icon: const Icon(Icons.close),
                  ),
              ],
            ),
            if (n.itemId == _other) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: n.otherName,
                      decoration: const InputDecoration(labelText: 'Item'),
                      validator: (v) =>
                          (v ?? '').trim().isEmpty ? 'Required' : null,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextFormField(
                      controller: n.otherUnit,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Unit',
                        hintText: 'pcs, boxes',
                      ),
                      validator: (v) =>
                          (v ?? '').trim().isEmpty ? 'Required' : null,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            TextFormField(
              controller: n.qty,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'How many?',
                suffixText: unit.isEmpty ? null : unit,
              ),
              validator: _num,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: api.lookups(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final names = Names(snap.data!);
        final sitios = names
            .rows('sitios')
            .where((s) => '${s['barangay_id']}' == brgyId)
            .toList();
        return Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const PageHeader(
                'Submit Post-Disaster Report',
                subtitle:
                    'Saved as Pending until the Administrator validates it.',
              ),
              const SectionTitle('Disaster and location'),
              LookupDropdown(
                list: 'disaster_types',
                label: 'Disaster type',
                value: typeId,
                names: names,
                onChanged: (v) => setState(() => typeId = v),
              ),
              const SizedBox(height: 12),
              LookupDropdown(
                list: 'barangays',
                label: 'Barangay',
                value: brgyId,
                names: names,
                onChanged: (v) => setState(() {
                  brgyId = v;
                  sitioId = null;
                }),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey('sitio-$brgyId'),
                initialValue: sitioId,
                isExpanded: true,
                items: [
                  const DropdownMenuItem(value: '', child: Text('(none)')),
                  for (final s in sitios)
                    DropdownMenuItem(
                      value: '${s['id']}',
                      child: Text('${s['name']}'),
                    ),
                ],
                onChanged: brgyId == null ? null : (v) => sitioId = v,
                decoration: InputDecoration(
                  labelText: 'Sitio (optional)',
                  helperText: brgyId == null ? 'Choose a barangay first' : null,
                ),
              ),
              const SectionTitle('Situation (DROMIC)'),
              TextFormField(
                controller: desc,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Short incident description',
                ),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: families,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Affected families',
                ),
                validator: _num,
              ),
              SectionTitle(
                'Assistance needed',
                trailing: TextButton.icon(
                  onPressed: () => setState(() => needs.add(_Need())),
                  icon: const Icon(Icons.add),
                  label: const Text('Add need'),
                ),
              ),
              for (var i = 0; i < needs.length; i++) _needRow(i, names),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: busy ? null : () => _submit(names),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                ),
                icon: const Icon(Icons.send),
                label: const Text('Submit report'),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// UC-CD2 / UC-B2 needs monitoring: reports with fulfillment progress
// ---------------------------------------------------------------------------
class MonitoringScreen extends StatefulWidget {
  const MonitoringScreen({super.key});

  @override
  State<MonitoringScreen> createState() => _MonitoringScreenState();
}

class _MonitoringScreenState extends State<MonitoringScreen> {
  String priority = '';

  @override
  Widget build(BuildContext context) {
    return Loader(
      key: ValueKey(priority),
      load: [
        () => api.get(
          '/reports/monitoring',
          query: {if (priority.isNotEmpty) 'priority_level': priority},
        ),
        api.lookupsResult,
      ],
      builder: (context, data) {
        final rows = (data[0] as List).cast<Map<String, dynamic>>();
        final names = Names(Map<String, dynamic>.from(data[1] as Map));
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            PageHeader(
              'Active Reports',
              subtitle:
                  'Needs monitoring with fulfillment progress • ${roleLine()}',
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final p in const [
                    '',
                    'Critical',
                    'High',
                    'Medium',
                    'Low',
                    'Needs Review',
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(p.isEmpty ? 'All' : p),
                        selected: priority == p,
                        onSelected: (_) => setState(() => priority = p),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (rows.isEmpty) const EmptyState('No reports to show.'),
            for (final r in rows) ReportCard(r, names),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// UC-A3 Process reports (Administrator)
// ---------------------------------------------------------------------------
class AdminReportsScreen extends StatefulWidget {
  const AdminReportsScreen({super.key});

  @override
  State<AdminReportsScreen> createState() => _AdminReportsScreenState();
}

class _AdminReportsScreenState extends State<AdminReportsScreen> {
  String status = 'Pending';

  Future<void> _reject(Map<String, dynamic> r) async {
    final v = await formDialog(
      context,
      title: 'Reject report #${r['report_id']}',
      message: 'The reason is sent back so the report can be corrected.',
      fields: const [DialogField('reason', 'Reason', multiline: true)],
      confirm: 'Reject',
    );
    if (v == null || !mounted) return;
    await act(
      context,
      () => api.post(
        '/reports/${r['report_id']}/reject',
        body: {'rejection_reason': v['reason']},
      ),
      success: 'Report #${r['report_id']} rejected',
    );
  }

  Future<void> _encodeSms(Names names) async {
    final types = names.rows('disaster_types');
    final brgys = names.rows('barangays');
    if (types.isEmpty || brgys.isEmpty) return;
    final v = await formDialog(
      context,
      title: 'Encode SMS report',
      message: 'UC-A3 step 8a: type in a report received by SMS.',
      fields: [
        const DialogField('contact', 'Sender number'),
        const DialogField('raw', 'SMS text as received', multiline: true),
        DialogField(
          'type',
          'Disaster type',
          initial: '${types.first['name']}',
          options: [for (final t in types) '${t['name']}'],
        ),
        DialogField(
          'brgy',
          'Barangay',
          initial: '${brgys.first['name']}',
          options: [for (final b in brgys) '${b['name']}'],
        ),
        const DialogField('families', 'Affected families', number: true),
        const DialogField('needs', 'Assistance needed'),
        const DialogField('qty', 'Estimated quantity', number: true),
      ],
      confirm: 'Encode',
    );
    if (v == null || !mounted) return;
    int idOf(List<Map<String, dynamic>> rows, String name) =>
        rows.firstWhere((r) => r['name'] == name)['id'] as int;
    await act(
      context,
      () => api.post(
        '/reports/sms',
        body: {
          'contact_number': v['contact'],
          'raw_message': v['raw'],
          'disaster_type_id': idOf(types, v['type']!),
          'barangay_id': idOf(brgys, v['brgy']!),
          'affected_families': int.tryParse(v['families']!),
          'assistance_needed': v['needs'],
          'estimated_quantity': int.tryParse(v['qty']!),
        },
      ),
      success: 'SMS report encoded. It is now in the pending list.',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Loader(
      key: ValueKey(status),
      load: [
        () => api.get('/reports/', query: {'status': status}),
        api.lookupsResult,
      ],
      builder: (context, data) {
        final rows = (data[0] as List).cast<Map<String, dynamic>>();
        final names = Names(Map<String, dynamic>.from(data[1] as Map));
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            PageHeader('Report Validation', subtitle: roleLine()),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'Pending', label: Text('Pending')),
                ButtonSegment(value: 'Validated', label: Text('Validated')),
                ButtonSegment(value: 'Rejected', label: Text('Rejected')),
              ],
              selected: {status},
              onSelectionChanged: (s) => setState(() => status = s.first),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => _encodeSms(names),
                icon: const Icon(Icons.sms_outlined),
                label: const Text('Encode SMS report'),
              ),
            ),
            if (rows.isEmpty) EmptyState('No ${status.toLowerCase()} reports.'),
            for (final r in rows)
              ReportCard(
                r,
                names,
                actions: status == 'Pending'
                    ? [
                        OutlinedButton(
                          onPressed: () => _reject(r),
                          child: const Text('Reject'),
                        ),
                        FilledButton.icon(
                          onPressed: () => act(
                            context,
                            () =>
                                api.post('/reports/${r['report_id']}/validate'),
                            success:
                                'Report #${r['report_id']} validated and published to donors',
                          ),
                          icon: const Icon(Icons.check),
                          label: const Text('Validate'),
                        ),
                      ]
                    : const [],
              ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// UC-A1 Manage internal accounts (Administrator)
// ---------------------------------------------------------------------------
class AccountsScreen extends StatefulWidget {
  const AccountsScreen({super.key});

  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  final _form = GlobalKey<FormState>();
  final c = {
    for (final k in const ['first', 'last', 'email', 'phone', 'password'])
      k: TextEditingController(),
  };
  String role = Roles.cswsMain;
  String? brgyId;
  bool busy = false;

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => busy = true);
    final r = await act(
      context,
      () => api.post(
        '/admin/users',
        body: {
          'first_name': c['first']!.text.trim(),
          'last_name': c['last']!.text.trim(),
          'email': c['email']!.text.trim(),
          'contact_number': c['phone']!.text.trim(),
          'password': c['password']!.text,
          'role_name': role,
          'assigned_barangay_id': role == Roles.barangay && brgyId != null
              ? int.parse(brgyId!)
              : null,
        },
      ),
      success: 'Account created for ${c['email']!.text.trim()}',
    );
    if (!mounted) return;
    setState(() => busy = false);
    if (r.ok) {
      for (final t in c.values) {
        t.clear();
      }
    }
  }

  Widget _f(String k, String label, {bool obscure = false, int min = 1}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextFormField(
          controller: c[k],
          obscureText: obscure,
          decoration: InputDecoration(labelText: label),
          validator: (v) =>
              (v ?? '').trim().length < min ? 'At least $min characters' : null,
        ),
      );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: api.lookups(),
      builder: (context, snap) {
        final names = Names(snap.data ?? const {});
        return Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              PageHeader(
                'User Management',
                subtitle:
                    'Create internal accounts for office-based roles (UC-A1) • ${roleLine()}',
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: role,
                isExpanded: true,
                items: [
                  for (final r in const [
                    Roles.cswsUnit,
                    Roles.cswsMain,
                    Roles.cmo,
                    Roles.drrmo,
                    Roles.barangay,
                  ])
                    DropdownMenuItem(value: r, child: Text(r)),
                ],
                onChanged: (v) => setState(() => role = v!),
                decoration: const InputDecoration(labelText: 'Role'),
              ),
              const SizedBox(height: 12),
              if (role == Roles.barangay) ...[
                LookupDropdown(
                  list: 'barangays',
                  label: 'Assigned barangay',
                  value: brgyId,
                  names: names,
                  onChanged: (v) => setState(() => brgyId = v),
                ),
                const SizedBox(height: 12),
              ],
              _f('first', 'First name'),
              _f('last', 'Last name'),
              _f('email', 'Email'),
              _f('phone', 'Contact number', min: 7),
              _f('password', 'Temporary password', obscure: true, min: 8),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: busy ? null : _submit,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                icon: const Icon(Icons.person_add_alt),
                label: const Text('Create account'),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Dashboards (UC-A4, UC-CD2, UC-CM3, UC-B2)
// ---------------------------------------------------------------------------
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [
        () => api.get('/dashboard/summary'),
        () => api.get('/dashboard/reports-breakdown'),
        () => api.get('/dashboard/fulfillment'),
        () => api.get('/dashboard/logistics'),
      ],
      builder: (context, d) {
        final s = d[0] as Map,
            b = d[1] as Map,
            f = d[2] as Map,
            l = d[3] as Map;
        Widget bars(
          String title,
          List rows,
          String key,
          Color Function(String?) tone,
        ) {
          final total = rows.fold<int>(0, (a, r) => a + (r['count'] as int));
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  if (rows.isEmpty) const Text('No data yet'),
                  for (final r in rows)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 100,
                            child: Text('${r[key] ?? 'None'}'),
                          ),
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: total == 0 ? 0 : r['count'] / total,
                                minHeight: 10,
                                color: tone(r[key] as String?),
                                backgroundColor: Colors.black12,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 36,
                            child: Text(
                              '${r['count']}',
                              textAlign: TextAlign.right,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          );
        }

        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            PageHeader(
              '${api.role ?? 'System'} Dashboard',
              subtitle: roleLine(),
            ),
            StatGrid([
              StatTile(
                'Disaster reports',
                '${s['total_reports']}',
                Icons.report_outlined,
              ),
              StatTile(
                'Physical donations',
                '${s['total_donations']}',
                Icons.volunteer_activism_outlined,
              ),
              StatTile(
                'Deliveries',
                '${s['total_deliveries']}',
                Icons.local_shipping_outlined,
              ),
              StatTile(
                'Logistics requests',
                '${s['total_logistics_requests']}',
                Icons.fire_truck_outlined,
              ),
              StatTile(
                'Average fulfillment',
                '${(f['average_fulfillment_percentage'] as num).toStringAsFixed(0)}%',
                Icons.pie_chart_outline,
                color: const Color(0xFF2E7D32),
              ),
              StatTile(
                'Est. value of donations',
                'PHP ${(b['total_estimated_value'] as num).toStringAsFixed(0)}',
                Icons.payments_outlined,
              ),
            ]),
            const SizedBox(height: 12),
            bars(
              'Reports by status',
              b['by_status'] as List,
              'status',
              statusTone,
            ),
            bars(
              'Reports by priority',
              b['by_priority'] as List,
              'priority_level',
              priorityTone,
            ),
            bars(
              'Deliveries by status',
              l['deliveries_by_status'] as List,
              'status',
              statusTone,
            ),
            bars(
              'Logistics requests by status',
              l['requests_by_status'] as List,
              'status',
              statusTone,
            ),
          ],
        );
      },
    );
  }
}
