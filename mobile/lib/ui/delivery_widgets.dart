import 'package:flutter/material.dart';

import '../api.dart' show ApiResult;

import 'widgets.dart';

// ---------------------------------------------------------------------------
// Pieces shared by "Prepare delivery" (one report) and "Plan a trip"
// (several reports), so both screens look and behave the same:
//
//   pickReportWithStock()  choose a report from a searchable list. Only
//                          reports with goods in stock can be picked.
//   StockQuantities        every item in stock as a row with a quantity box
//                          (no dropdowns, works with many items), search
//                          when the list is long.
//   pickDeliveryDateTime() date, then time, sent to the server in UTC so the
//                          time is the same on every phone and the server.
//   showDeliveryProblems() "Something went wrong?" options for a delivery.
// ---------------------------------------------------------------------------

/// Priority order for sorting (most urgent first).
int _rank(String? p) => PriorityColors.rank(p);

/// Plain "Fri, Oct 12 · 2:00 PM" for buttons and summaries.
String niceWhen(dynamic iso) {
  final d = DateTime.tryParse('${iso ?? ''}');
  if (d == null) return '';
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final l = d.toLocal();
  final h = l.hour % 12 == 0 ? 12 : l.hour % 12;
  final m = l.minute.toString().padLeft(2, '0');
  return '${days[l.weekday - 1]}, ${months[l.month - 1]} ${l.day} · '
      '$h:$m ${l.hour < 12 ? 'AM' : 'PM'}';
}

/// Date, then time. Returns an ISO string in UTC ("...Z"), or null if the
/// user backed out. Past dates cannot be picked.
Future<String?> pickDeliveryDateTime(
  BuildContext context, {
  String? current,
  String help = 'When will it leave?',
}) async {
  final now = DateTime.now();
  final cur = DateTime.tryParse('${current ?? ''}')?.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = await showDatePicker(
    context: context,
    helpText: help,
    firstDate: today,
    lastDate: today.add(const Duration(days: 365)),
    initialDate: cur != null && !cur.isBefore(today) ? cur : today,
  );
  if (day == null || !context.mounted) return null;
  final time = await showTimePicker(
    context: context,
    helpText: 'What time?',
    initialTime: cur != null
        ? TimeOfDay.fromDateTime(cur)
        : const TimeOfDay(hour: 8, minute: 0),
  );
  if (time == null) return null;
  return DateTime(
    day.year,
    day.month,
    day.day,
    time.hour,
    time.minute,
  ).toUtc().toIso8601String();
}

/// A big, obvious date field: shows the chosen date or asks for one, and
/// turns red with [error] when it is missing.
class DateField extends StatelessWidget {
  final String label;
  final String? value; // ISO
  final String? error;
  final VoidCallback onTap;
  const DateField({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.md),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.event),
          suffixIcon: const Icon(Icons.edit_calendar_outlined),
          errorText: error,
        ),
        child: Text(
          value == null ? 'Tap to pick the date and time' : niceWhen(value),
          style: value == null
              ? TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)
              : null,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Report picker
// ---------------------------------------------------------------------------

/// [candidates] is GET /trips/candidates. Returns the chosen report row
/// (with its items in stock), or null.
Future<Map?> pickReportWithStock(BuildContext context, Map candidates) {
  final reports =
      <Map>[
        for (final g in (candidates['barangays'] as List).cast<Map>())
          ...(g['reports'] as List).cast<Map>(),
      ]..sort((a, b) {
        final p = _rank(a['priority_level'] as String?)
            .compareTo(_rank(b['priority_level'] as String?));
        return p != 0
            ? p
            : (a['report_id'] as int).compareTo(b['report_id'] as int);
      });
  final empty = (candidates['no_stock_reports'] as List).cast<Map>();
  return showModalBottomSheet<Map>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _ReportPickerSheet(reports: reports, empty: empty),
  );
}

class _ReportPickerSheet extends StatefulWidget {
  final List<Map> reports;
  final List<Map> empty;
  const _ReportPickerSheet({required this.reports, required this.empty});

  @override
  State<_ReportPickerSheet> createState() => _ReportPickerSheetState();
}

class _ReportPickerSheetState extends State<_ReportPickerSheet> {
  String q = '';

  bool _match(Map r) {
    final s = q.trim().toLowerCase().replaceAll('#', '');
    return s.isEmpty ||
        '${r['report_label']}'.toLowerCase().contains(s) ||
        '${r['barangay_name']}'.toLowerCase().contains(s);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final shown = widget.reports.where(_match).toList();
    final empty = widget.empty.where(_match).toList();
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.8,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Which report are these goods for?', style: t.titleLarge),
                Text(
                  'Only reports with goods in stock can be chosen. '
                  'Most urgent first.',
                  style: t.bodySmall,
                ),
                Gaps.v8,
                TextField(
                  autofocus: false,
                  decoration: const InputDecoration(
                    labelText: 'Search report no. or barangay',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (v) => setState(() => q = v),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: [
                if (shown.isEmpty)
                  const EmptyView(
                    compact: true,
                    icon: Icons.inventory_2_outlined,
                    title: 'No report with stock matches',
                    message: 'Receive donations first, or search again.',
                  ),
                for (final r in shown)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      onTap: () => Navigator.pop(context, r),
                      title: Text('${r['report_label']}'),
                      subtitle: Text(
                        '${(r['items'] as List).length} '
                        '${(r['items'] as List).length == 1 ? 'item' : 'items'} in stock · '
                        '${(r['fulfillment_percentage'] as num).round()}% fulfilled',
                      ),
                      trailing: PriorityChip(r['priority_level'] as String?),
                    ),
                  ),
                if (empty.isNotEmpty) ...[
                  Gaps.v16,
                  Text('No more stock', style: t.titleSmall),
                  for (final r in empty)
                    ListTile(
                      enabled: false,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.remove_shopping_cart_outlined),
                      title: Text('${r['report_label']}'),
                      subtitle: const Text('No more stock for this report'),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Item rows with quantity boxes
// ---------------------------------------------------------------------------

/// Every item of one report's stock as a row: name, how much is left, a
/// quantity box and an "All" button. Empty box = do not send that item.
/// Long lists get a search box. Validation messages show under each box.
class StockQuantities extends StatefulWidget {
  /// [{item_id, item_name, unit, quantity}] from GET /trips/candidates.
  final List<Map> items;

  /// Quantity box per item_id, owned by the parent screen.
  final TextEditingController Function(int itemId) controllerFor;
  final VoidCallback? onChanged;
  const StockQuantities({
    super.key,
    required this.items,
    required this.controllerFor,
    this.onChanged,
  });

  @override
  State<StockQuantities> createState() => _StockQuantitiesState();
}

class _StockQuantitiesState extends State<StockQuantities> {
  String q = '';

  void _set(int id, String v) {
    widget.controllerFor(id).text = v;
    widget.onChanged?.call();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final many = widget.items.length > 6;
    final shown = widget.items
        .where(
          (i) =>
              q.trim().isEmpty ||
              '${i['item_name']}'.toLowerCase().contains(
                q.trim().toLowerCase(),
              ),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${widget.items.length} '
                '${widget.items.length == 1 ? 'item' : 'items'} in stock. '
                'Leave a box empty to skip that item.',
                style: t.bodySmall,
              ),
            ),
            TextButton(
              onPressed: () {
                for (final i in widget.items) {
                  widget.controllerFor(i['item_id'] as int).text =
                      '${i['quantity']}';
                }
                widget.onChanged?.call();
                setState(() {});
              },
              child: const Text('Send everything'),
            ),
            TextButton(
              onPressed: () {
                for (final i in widget.items) {
                  widget.controllerFor(i['item_id'] as int).clear();
                }
                widget.onChanged?.call();
                setState(() {});
              },
              child: const Text('Clear'),
            ),
          ],
        ),
        if (many) ...[
          TextField(
            decoration: const InputDecoration(
              labelText: 'Find an item',
              prefixIcon: Icon(Icons.search),
              isDense: true,
            ),
            onChanged: (v) => setState(() => q = v),
          ),
          Gaps.v8,
        ],
        for (final i in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${i['item_name']}', style: t.titleSmall),
                        Text(
                          '${i['quantity']} ${i['unit'] ?? ''} left'.replaceAll(
                            '  ',
                            ' ',
                          ),
                          style: t.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
                Gaps.h8,
                Expanded(
                  flex: 2,
                  child: TextFormField(
                    controller: widget.controllerFor(i['item_id'] as int),
                    keyboardType: TextInputType.number,
                    onChanged: (_) => widget.onChanged?.call(),
                    decoration: InputDecoration(
                      labelText: 'Send',
                      isDense: true,
                      suffixIcon: TextButton(
                        onPressed: () =>
                            _set(i['item_id'] as int, '${i['quantity']}'),
                        child: const Text('All'),
                      ),
                    ),
                    validator: (v) {
                      final s = v?.trim() ?? '';
                      if (s.isEmpty) return null;
                      final n = int.tryParse(s);
                      if (n == null || n < 0) return 'Whole number';
                      if (n > (i['quantity'] as num)) {
                        return 'Only ${i['quantity']} left';
                      }
                      return null;
                    },
                  ),
                ),
              ],
            ),
          ),
        if (shown.isEmpty) Text('No item matches "$q".', style: t.bodySmall),
      ],
    );
  }
}

/// What a delivery carries (GET /deliveries/ready/{id}): every donation of
/// the report that the CMO acknowledged and that has not gone out yet, each
/// one WHOLE. Oct 15 (team): all start ticked; if they do not fit, Main
/// Office unticks whole donations (donor C's entry waits for the next
/// delivery). A donation is never split, so no quantities to type.
class ReadyDonations extends StatefulWidget {
  final int reportId;

  /// The ticked donation entries (batch references); empty = nothing to send.
  final ValueChanged<Set<String>>? onChanged;

  const ReadyDonations({super.key, required this.reportId, this.onChanged});

  @override
  State<ReadyDonations> createState() => _ReadyDonationsState();
}

class _ReadyDonationsState extends State<ReadyDonations> {
  late Future<ApiResult> _load = _fetch();
  final Set<String> _ticked = {};

  Future<ApiResult> _fetch() async {
    final r = await api.get('/deliveries/ready/${widget.reportId}');
    _ticked
      ..clear()
      ..addAll([
        if (r.ok && r.json is Map)
          for (final e in ((r.json as Map)['entries'] as List).cast<Map>())
            '${e['batch_reference']}',
      ]);
    widget.onChanged?.call({..._ticked});
    return r;
  }

  @override
  void didUpdateWidget(covariant ReadyDonations old) {
    super.didUpdateWidget(old);
    if (old.reportId != widget.reportId) _load = _fetch();
  }

  void _toggle(String ref, bool on) {
    setState(() => on ? _ticked.add(ref) : _ticked.remove(ref));
    widget.onChanged?.call({..._ticked});
  }

  String _amount(Map i) =>
      '${i['quantity']} ${i['unit'] ?? ''} ${i['item_name']}'
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return FutureBuilder<ApiResult>(
      future: _load,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final r = snap.data!;
        if (!r.ok || r.json is! Map) {
          return Text(r.errorText, style: TextStyle(color: cs.error));
        }
        final m = r.json as Map;
        final entries = (m['entries'] as List).cast<Map>();
        final waiting = (m['waiting_for_cmo'] as num? ?? 0).toInt();
        final waitNote = waiting == 0
            ? null
            : '$waiting ${waiting == 1 ? 'donation still waits' : 'donations still wait'} '
                  'for the CMO to acknowledge it. '
                  '${waiting == 1 ? 'It goes' : 'They go'} on the next delivery.';
        if (entries.isEmpty) {
          return EmptyView(
            key: const ValueKey('ready-none'),
            compact: true,
            icon: Icons.hourglass_top,
            title: 'Nothing to send yet',
            message:
                waitNote ??
                'No donation for this report is acknowledged by the CMO yet.',
          );
        }
        // Totals of the ticked donations only.
        final totals = <int, Map>{};
        for (final e in entries) {
          if (!_ticked.contains('${e['batch_reference']}')) continue;
          for (final i in (e['items'] as List).cast<Map>()) {
            final id = i['item_id'] as int;
            final sum = totals.putIfAbsent(id, () => {...i, 'quantity': 0});
            sum['quantity'] = (sum['quantity'] as num) + (i['quantity'] as num);
          }
        }
        final left = entries.length - _ticked.length;
        return AppCard(
          key: const ValueKey('ready-donations'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Donations on this delivery', style: t.titleSmall),
              Gaps.v4,
              Text(
                'Every donation the CMO acknowledged is ticked. If they do not '
                'all fit, untick whole donations; they wait for the next '
                'delivery. A donation is never split. Need a truck? Request '
                'transport from DRRMO.',
                style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
              Gaps.v12,
              if (totals.isEmpty)
                Text(
                  'Nothing ticked. Tick at least one donation.',
                  style: t.bodySmall?.copyWith(color: cs.error),
                )
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final i in totals.values)
                      Chip(
                        avatar: const Icon(
                          Icons.inventory_2_outlined,
                          size: 16,
                        ),
                        label: Text(_amount(i)),
                      ),
                  ],
                ),
              Gaps.v8,
              Text(
                '${_ticked.length} of ${entries.length} '
                '${entries.length == 1 ? 'donation' : 'donations'} going'
                '${left > 0 ? ' · $left waiting for the next delivery' : ''}',
                style: t.labelLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              for (final e in entries)
                CheckboxListTile(
                  key: ValueKey('ready-${e['batch_reference']}'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _ticked.contains('${e['batch_reference']}'),
                  onChanged: (v) =>
                      _toggle('${e['batch_reference']}', v ?? false),
                  title: Text('${e['donor']} · ${e['batch_reference']}'),
                  subtitle: Text(
                    (e['items'] as List).cast<Map>().map(_amount).join(', '),
                  ),
                ),
              if (waitNote != null) ...[
                Gaps.v8,
                Text(
                  waitNote,
                  style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Lines to send for one report: [{item_id, quantity}] with quantity > 0.
List<Map<String, int>> linesFrom(
  List<Map> items,
  TextEditingController Function(int itemId) controllerFor,
) => [
  for (final i in items)
    if ((int.tryParse(controllerFor(i['item_id'] as int).text.trim()) ?? 0) > 0)
      {
        'item_id': i['item_id'] as int,
        'quantity': int.parse(controllerFor(i['item_id'] as int).text.trim()),
      },
];

// ---------------------------------------------------------------------------
// Something went wrong?
// ---------------------------------------------------------------------------

/// Asks for a reason with one-tap choices. Returns the reason or null.
Future<String?> askReason(
  BuildContext context, {
  required String title,
  required String message,
  required List<String> choices,
  required String confirm,
  bool danger = false,
}) async {
  String? picked;
  final other = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final text = picked == '__other' ? other.text.trim() : picked;
        return AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message),
                Gaps.v12,
                RadioGroup<String>(
                  groupValue: picked,
                  onChanged: (v) => setLocal(() => picked = v),
                  child: Column(
                    children: [
                      for (final c in choices)
                        RadioListTile<String>(
                          value: c,
                          title: Text(c),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      const RadioListTile<String>(
                        value: '__other',
                        title: Text('Something else'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                ),
                if (picked == '__other')
                  TextField(
                    controller: other,
                    maxLength: 300,
                    decoration: const InputDecoration(
                      labelText: 'What happened?',
                    ),
                    onChanged: (_) => setLocal(() {}),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Go back'),
            ),
            FilledButton(
              style: danger
                  ? FilledButton.styleFrom(backgroundColor: AppColors.danger)
                  : null,
              onPressed: (text ?? '').length >= 3
                  ? () => Navigator.pop(ctx, true)
                  : null,
              child: Text(confirm),
            ),
          ],
        );
      },
    ),
  );
  final reason = picked == '__other' ? other.text.trim() : picked;
  return ok == true ? reason : null;
}

/// "Something went wrong?" for one delivery (CSWS). [request] is the latest
/// DRRMO request for it, if any. Each option says what will happen.
Future<void> showDeliveryProblems(
  BuildContext context,
  Map d, {
  Map? request,
}) async {
  final status = '${d['status']}';
  final id = d['delivery_id'];
  final reqStage = request?['stage'] as String?;
  final openRequest = reqStage == 'Pending' || reqStage == 'Accepted';
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'What happened to delivery #$id?',
              style: Theme.of(ctx).textTheme.titleLarge,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.event_repeat),
            title: const Text('The date or time changed'),
            subtitle: const Text('Pick a new date. The barangay is told.'),
            onTap: () => Navigator.pop(ctx, 'date'),
          ),
          if (status == 'In Transit')
            ListTile(
              leading: const Icon(Icons.u_turn_left),
              title: const Text('The truck came back with the goods'),
              subtitle: const Text(
                'Breakdown, road closed, nobody to receive. It goes back '
                'to "Active" so you can send it again or cancel it.',
              ),
              onTap: () => Navigator.pop(ctx, 'back'),
            ),
          if (status == 'Preparing')
            ListTile(
              leading: Icon(Icons.block, color: AppColors.danger),
              title: const Text('This delivery will not happen'),
              subtitle: const Text(
                'Cancel it. The goods go back to the report\'s stock.',
              ),
              onTap: () => Navigator.pop(ctx, 'cancel'),
            ),
          if (openRequest)
            ListTile(
              leading: const Icon(Icons.fire_truck_outlined),
              title: const Text('We no longer need DRRMO\'s truck'),
              subtitle: const Text('Cancel the transport request.'),
              onTap: () => Navigator.pop(ctx, 'request'),
            ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  switch (choice) {
    case 'date':
      {
        final when = await pickDeliveryDateTime(
          context,
          current: d['delivery_date'] as String?,
          help: 'New delivery date',
        );
        if (when == null || !context.mounted) return;
        await act(
          context,
          () => api.post(
            '/deliveries/$id/reschedule',
            body: {'delivery_date': when},
          ),
          success: 'Delivery #$id moved to ${niceWhen(when)}',
        );
      }
    case 'back':
      {
        final why = await askReason(
          context,
          title: 'Truck came back',
          message: 'Delivery #$id goes back to "Active". Why?',
          choices: const [
            'The truck broke down',
            'The road is closed or unsafe',
            'Nobody was there to receive it',
            'Bad weather',
          ],
          confirm: 'Bring it back',
        );
        if (why == null || !context.mounted) return;
        await act(
          context,
          () => api.post(
            '/deliveries/$id/return-to-office',
            body: {'reason': why},
          ),
          success: 'Delivery #$id is back at the office',
        );
      }
    case 'cancel':
      {
        final why = await askReason(
          context,
          title: 'Cancel delivery #$id?',
          message:
              'The goods go back to the report\'s stock and can be sent '
              'later. Any DRRMO request for it is cancelled too. Why?',
          choices: const [
            'No truck available',
            'The road is closed or unsafe',
            'The barangay is not ready to receive',
            'Prepared by mistake',
          ],
          confirm: 'Cancel delivery',
          danger: true,
        );
        if (why == null || !context.mounted) return;
        await act(
          context,
          () => api.post('/deliveries/$id/cancel', body: {'reason': why}),
          success: 'Delivery #$id cancelled. The goods are back in stock.',
        );
      }
    case 'request':
      {
        final why = await askReason(
          context,
          title: 'Cancel the DRRMO request?',
          message: 'DRRMO will be told they do not need to come.',
          choices: const [
            'We found another vehicle',
            'The delivery date changed',
            'The delivery was cancelled',
          ],
          confirm: 'Cancel request',
        );
        if (why == null || !context.mounted) return;
        await act(
          context,
          () => api.post(
            '/logistics/requests/${request!['request_id']}/cancel',
            body: {'reason': why},
          ),
          success: 'DRRMO request cancelled',
        );
      }
  }
}
