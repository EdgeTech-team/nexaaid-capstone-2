import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'widgets.dart';

// ---------------------------------------------------------------------------
// NF-003 (Nov 2026): one report form for several barangays, e.g. an
// earthquake. The Disaster Unit picks the barangays (or "All barangays"),
// types the affected families of each, and enters the needs ONCE, per
// family. The app works out each barangay's amounts (families x per-family
// amount, rounded up) and POST /reports/batch saves one report per barangay,
// grouped as one event. The server only ever receives whole numbers.
// ---------------------------------------------------------------------------

const _months = [
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

/// "Earthquake – Nov 9, 2026": the event name the form suggests.
String defaultEventName(String disaster, DateTime day) =>
    '$disaster – ${_months[day.month - 1]} ${day.day}, ${day.year}';

/// One barangay's amount: ceil(families x per-family). 40 x 0.2 = 8,
/// 41 x 0.2 = 8.2 -> 9.
int barangayQuantity(int families, int hundredths) =>
    (families * hundredths + 99) ~/ 100;

/// A per-family amount from the server (6, 0.1, 0.25) in hundredths.
int hundredthsOf(num value) => (value * 100).round();

/// "1,440" (thousands separators for the totals).
String withCommas(int n) =>
    n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

/// One item of a barangay's report in the preview: whole quantity + unit.
class PreviewNeed {
  final String item;
  final int quantity;
  final String unit;
  const PreviewNeed(this.item, this.quantity, this.unit);
}

/// One barangay (= one report) in the preview.
class PreviewBarangay {
  final String name;
  final int families;
  final List<PreviewNeed> needs;
  const PreviewBarangay(this.name, this.families, this.needs);
}

/// "Several barangays": the check before submitting. A full-screen page
/// with the totals first, then one card per barangay: its name highlighted,
/// its affected families, and the items it needs (whole numbers, already
/// rounded up). Returns true when the reporter taps Submit.
Future<bool> showMultiReportPreview(
  BuildContext context, {
  required String eventName,
  required String disaster,
  required List<PreviewBarangay> barangays,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => Dialog.fullscreen(
      child: MultiReportPreview(
        eventName: eventName,
        disaster: disaster,
        barangays: barangays,
      ),
    ),
  );
  return ok == true;
}

class MultiReportPreview extends StatelessWidget {
  final String eventName;
  final String disaster;
  final List<PreviewBarangay> barangays;
  const MultiReportPreview({
    super.key,
    required this.eventName,
    required this.disaster,
    required this.barangays,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final n = barangays.length;
    final families = barangays.fold<int>(0, (a, b) => a + b.families);
    // Totals per item over every barangay, in the order of the needs.
    final totals = <String, (int, String)>{};
    for (final b in barangays) {
      for (final need in b.needs) {
        final was = totals[need.item];
        totals[need.item] = ((was?.$1 ?? 0) + need.quantity, need.unit);
      }
    }
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back to the form',
          onPressed: () => Navigator.pop(context, false),
          icon: const Icon(Icons.close),
        ),
        title: const Text('Check before submitting'),
      ),
      body: ListView(
        key: const ValueKey('multi-preview'),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text(eventName, style: t.titleLarge),
          Gaps.v4,
          Text(
            '$disaster · $n barangays · ${withCommas(families)} affected '
            'families',
            style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          Gaps.v8,
          Text(
            'Each barangay is saved as its own report. The Administrator '
            'validates each one before donors see it.',
            style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          Gaps.v16,
          Card(
            key: const ValueKey('multi-preview-totals'),
            color: cs.surfaceContainerHighest,
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Total for all $n barangays', style: t.titleSmall),
                  Gaps.v8,
                  for (final e in totals.entries)
                    _ItemLine(e.key, e.value.$1, e.value.$2),
                ],
              ),
            ),
          ),
          Gaps.v16,
          for (final b in barangays) ...[
            Card(
              key: ValueKey('multi-preview-${b.name}'),
              margin: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: cs.outlineVariant),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // The barangay, highlighted, with its families.
                  Container(
                    color: cs.primaryContainer,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.place, color: cs.onPrimaryContainer),
                        Gaps.h8,
                        Expanded(
                          child: Text(
                            b.name,
                            style: t.titleMedium?.copyWith(
                              color: cs.onPrimaryContainer,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: cs.surface,
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: Text(
                            '${withCommas(b.families)} '
                            '${b.families == 1 ? 'family' : 'families'}',
                            style: t.labelLarge?.copyWith(color: cs.primary),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Needed items',
                          style: t.labelMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        Gaps.v4,
                        for (final need in b.needs)
                          _ItemLine(need.item, need.quantity, need.unit),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Gaps.v12,
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, false),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  child: const Text('Back to edit'),
                ),
              ),
              Gaps.h12,
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  key: const ValueKey('multi-preview-submit'),
                  onPressed: () => Navigator.pop(context, true),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  icon: const Icon(Icons.send),
                  label: Text('Submit $n reports'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One saved report of a "Several barangays" submission.
class SubmittedReport {
  final int reportId;
  final PreviewBarangay barangay;
  const SubmittedReport(this.reportId, this.barangay);
}

/// After "Several barangays" is submitted: every saved report in one
/// sortable, searchable list. Returns true for "View report status".
Future<bool> showMultiReportSubmitted(
  BuildContext context, {
  required String eventName,
  required List<SubmittedReport> reports,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => Dialog.fullscreen(
      child: MultiReportSubmitted(eventName: eventName, reports: reports),
    ),
  );
  return ok == true;
}

enum _SubmittedSort { families, name, number }

class MultiReportSubmitted extends StatefulWidget {
  final String eventName;
  final List<SubmittedReport> reports;
  const MultiReportSubmitted({
    super.key,
    required this.eventName,
    required this.reports,
  });

  @override
  State<MultiReportSubmitted> createState() => _MultiReportSubmittedState();
}

class _MultiReportSubmittedState extends State<MultiReportSubmitted> {
  var _sort = _SubmittedSort.families;
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<SubmittedReport> get _shown {
    final q = _search.text.trim().toLowerCase();
    final rows = [
      for (final r in widget.reports)
        if (q.isEmpty || r.barangay.name.toLowerCase().contains(q)) r,
    ];
    rows.sort(
      (a, b) => switch (_sort) {
        _SubmittedSort.families => b.barangay.families.compareTo(
          a.barangay.families,
        ),
        _SubmittedSort.name => a.barangay.name.compareTo(b.barangay.name),
        _SubmittedSort.number => a.reportId.compareTo(b.reportId),
      },
    );
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final n = widget.reports.length;
    final families = widget.reports.fold<int>(
      0,
      (a, r) => a + r.barangay.families,
    );
    final shown = _shown;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Close',
          onPressed: () => Navigator.pop(context, false),
          icon: const Icon(Icons.close),
        ),
        title: const Text('Reports submitted'),
      ),
      body: ListView(
        key: const ValueKey('multi-submitted'),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Row(
            children: [
              Icon(Icons.check_circle, color: cs.primary, size: 32),
              Gaps.h12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.eventName, style: t.titleLarge),
                    Text(
                      '$n reports · ${withCommas(families)} affected families',
                      style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Gaps.v8,
          Text(
            'Each report is Pending until the Administrator validates it. '
            'Follow them on Reports › Status.',
            style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          Gaps.v16,
          if (n > 6) ...[
            TextField(
              key: const ValueKey('multi-submitted-search'),
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search a barangay',
                isDense: true,
              ),
            ),
            Gaps.v8,
          ],
          Row(
            children: [
              Text('Sort by', style: t.labelLarge),
              Gaps.h8,
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final (s, label) in const [
                        (_SubmittedSort.families, 'Most families'),
                        (_SubmittedSort.name, 'Name A–Z'),
                        (_SubmittedSort.number, 'Report no.'),
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text(label),
                            selected: _sort == s,
                            onSelected: (_) => setState(() => _sort = s),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          Gaps.v8,
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'No barangay matches "${_search.text.trim()}".',
                textAlign: TextAlign.center,
                style: t.bodyMedium,
              ),
            ),
          for (final r in shown)
            Card(
              key: ValueKey('multi-submitted-${r.reportId}'),
              margin: const EdgeInsets.only(bottom: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: cs.outlineVariant),
              ),
              child: ExpansionTile(
                shape: const Border(),
                leading: CircleAvatar(
                  backgroundColor: cs.primaryContainer,
                  child: Icon(Icons.place, color: cs.onPrimaryContainer),
                ),
                title: Text(
                  r.barangay.name,
                  style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  'Report #${r.reportId} · '
                  '${withCommas(r.barangay.families)} '
                  '${r.barangay.families == 1 ? 'family' : 'families'}',
                ),
                trailing: Chip(
                  label: const Text('Pending'),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: cs.secondaryContainer,
                  side: BorderSide.none,
                ),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                children: [
                  for (final need in r.barangay.needs)
                    _ItemLine(need.item, need.quantity, need.unit),
                ],
              ),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, false),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  child: const Text('New report'),
                ),
              ),
              Gaps.h12,
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  key: const ValueKey('multi-submitted-status'),
                  onPressed: () => Navigator.pop(context, true),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  icon: const Icon(Icons.monitor_heart_outlined),
                  label: const Text('View report status'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Rice ........ 720 kg" (item left, whole quantity right).
class _ItemLine extends StatelessWidget {
  final String item;
  final int quantity;
  final String unit;
  const _ItemLine(this.item, this.quantity, this.unit);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(item, style: t.bodyMedium)),
          Text(
            '${withCommas(quantity)} $unit'.trim(),
            style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

/// The barangays of the form, with what was typed for each:
/// barangay id -> affected families field.
typedef BarangayRows = Map<String, TextEditingController>;

/// One barangay's totals as a short line, e.g. "Rice 720 kg · Water 2,400 L"
/// (null = nothing to show yet). Given by the report form.
typedef BarangayPreview = String? Function(String id, int families);

/// The barangay part of the form in "Several barangays" mode.
///
/// "Affected barangays" looks like a dropdown; tapping it opens a checklist
/// with a search box and "Select all" ("Select all prone" for a
/// location-specific type, prone barangays first and tagged). The picked
/// barangays come back as rows with an "Affected families" field and, once
/// the families are typed, that barangay's totals. A barangay left blank or
/// at 0 is not submitted. A barangay not tagged as prone is never blocked:
/// one "Continue?" asks about all of them together (NF-004 soft warning).
class MultiBarangayPicker extends StatefulWidget {
  final Names names;
  final String? typeId;
  final BarangayRows rows;
  final VoidCallback onChanged;
  final int maxFamilies;
  final BarangayPreview? preview;
  const MultiBarangayPicker({
    super.key,
    required this.names,
    required this.typeId,
    required this.rows,
    required this.onChanged,
    required this.maxFamilies,
    this.preview,
  });

  @override
  State<MultiBarangayPicker> createState() => _MultiBarangayPickerState();
}

class _MultiBarangayPickerState extends State<MultiBarangayPicker> {
  /// Prone barangay ids per disaster type id, loaded once per type.
  static final _prone = <String, Future<Set<String>>>{};

  bool get _locationSpecific =>
      widget.typeId != null &&
      widget.names
          .rows('disaster_types')
          .any(
            (t) =>
                '${t['id']}' == widget.typeId &&
                t['is_location_specific'] == true,
          );

  String get _typeName =>
      widget.names.of('disaster_types', widget.typeId, fallback: 'it');

  Future<Set<String>> _load(String typeId) => _prone[typeId] ??= api
      .get('/lookups/barangays', query: {'disaster_type_id': typeId})
      .then((r) {
        if (!r.ok || r.json is! List) {
          _prone.remove(typeId);
          return <String>{};
        }
        return {
          for (final b in r.json as List)
            if (b is Map && b['is_hazard_prone'] == true) '${b['id']}',
        };
      });

  List<Map<String, dynamic>> _sorted(Set<String> prone) =>
      widget.names.rows('barangays')..sort((a, b) {
        final pa = prone.contains('${a['id']}') ? 0 : 1;
        final pb = prone.contains('${b['id']}') ? 0 : 1;
        return pa != pb ? pa - pb : '${a['name']}'.compareTo('${b['name']}');
      });

  void _remove(String id) {
    widget.rows.remove(id)?.dispose();
    widget.onChanged();
  }

  /// Keeps what was typed for barangays that stay picked.
  void _apply(Set<String> picked) {
    for (final id in widget.rows.keys.toList()) {
      if (!picked.contains(id)) widget.rows.remove(id)?.dispose();
    }
    for (final id in picked) {
      widget.rows.putIfAbsent(id, TextEditingController.new);
    }
    widget.onChanged();
  }

  Future<void> _open(Set<String> prone) async {
    final tagged = _locationSpecific && prone.isNotEmpty;
    final all = _sorted(prone);
    final picked = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) => _BarangayChecklist(
        barangays: all,
        prone: tagged ? prone : const {},
        typeName: _typeName,
        initial: widget.rows.keys.toSet(),
      ),
    );
    if (picked == null || !mounted) return;
    final untagged = [
      for (final b in all)
        if (tagged &&
            picked.contains('${b['id']}') &&
            !widget.rows.containsKey('${b['id']}') &&
            !prone.contains('${b['id']}'))
          '${b['name']}',
    ];
    if (untagged.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Barangay not tagged'),
          content: Text(
            '${untagged.join(', ')} '
            '${untagged.length == 1 ? 'is' : 'are'} not tagged as prone to '
            '$_typeName. Continue?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Choose again'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (ok != true) return _open(prone);
    }
    _apply(picked);
  }

  @override
  Widget build(BuildContext context) {
    if (!_locationSpecific) return _body(const {});
    return FutureBuilder<Set<String>>(
      future: _load(widget.typeId!),
      builder: (context, snap) => _body(snap.data ?? const {}),
    );
  }

  Widget _body(Set<String> prone) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final picked = [
      for (final b in _sorted(prone))
        if (widget.rows.containsKey('${b['id']}')) b,
    ];
    final count = picked.length;
    return FormField<int>(
      // Re-checked on submit: at least 2 barangays with families.
      validator: (_) => count == 0 ? 'Choose the affected barangays' : null,
      builder: (field) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // A button for screen readers too ("Affected barangays, 3
          // barangays selected").
          Semantics(
            button: true,
            label: count == 0
                ? 'Affected barangays'
                : 'Affected barangays, ${count == 1 ? picked.first['name'] : '$count barangays selected'}',
            excludeSemantics: true,
            child: InkWell(
              key: const ValueKey('barangay-dropdown'),
              borderRadius: BorderRadius.circular(Radii.md),
              onTap: () => _open(prone),
              child: InputDecorator(
                isEmpty: count == 0,
                decoration: InputDecoration(
                  labelText: 'Affected barangays',
                  hintText: 'Tap to choose barangays',
                  helperText: _locationSpecific && prone.isNotEmpty
                      ? 'Barangays prone to $_typeName are listed first.'
                      : 'Each barangay becomes its own report.',
                  errorText: field.errorText,
                  suffixIcon: const Icon(Icons.arrow_drop_down),
                ),
                child: count == 0
                    ? null
                    : Text(
                        count == 1
                            ? '${picked.first['name']}'
                            : '$count barangays selected',
                        style: t.bodyLarge,
                      ),
              ),
            ),
          ),
          if (picked.isNotEmpty) ...[
            Gaps.v16,
            Text('Affected families in each barangay', style: t.titleSmall),
            Text(
              _summary(picked),
              key: const ValueKey('multi-summary'),
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            Gaps.v8,
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: cs.outlineVariant),
                borderRadius: BorderRadius.circular(Radii.md),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < picked.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    _row(picked[i], prone),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// "3 barangays · 2 with families (240 in all). A barangay left blank is
  /// skipped."
  String _summary(List<Map<String, dynamic>> picked) {
    var filled = 0;
    var families = 0;
    for (final b in picked) {
      final n = int.tryParse(widget.rows['${b['id']}']?.text.trim() ?? '') ?? 0;
      if (n > 0) {
        filled++;
        families += n;
      }
    }
    final count =
        '${picked.length} '
        '${picked.length == 1 ? 'barangay' : 'barangays'}';
    return filled == 0
        ? '$count chosen. Type the affected families of each; a barangay '
              'left blank is skipped.'
        : '$count · $filled with families (${withCommas(families)} in all). '
              'A barangay left blank is skipped.';
  }

  Widget _row(Map b, Set<String> prone) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final id = '${b['id']}';
    final controller = widget.rows[id]!;
    final families = int.tryParse(controller.text.trim()) ?? 0;
    final preview = families > 0 ? widget.preview?.call(id, families) : null;
    final untagged =
        _locationSpecific && prone.isNotEmpty && !prone.contains(id);
    return Padding(
      key: ValueKey('fam-row-$id'),
      padding: const EdgeInsets.fromLTRB(12, 8, 0, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${b['name']}',
                      style: t.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (untagged)
                      Text(
                        'Not tagged as prone to $_typeName',
                        style: t.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                flex: 2,
                child: TextFormField(
                  key: ValueKey('families-$id'),
                  controller: controller,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(6),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Families',
                    isDense: true,
                  ),
                  onChanged: (_) => widget.onChanged(),
                  validator: (v) {
                    final n = int.tryParse((v ?? '').trim());
                    if (n == null || n == 0) return null; // skipped
                    return n > widget.maxFamilies
                        ? 'Max ${widget.maxFamilies}'
                        : null;
                  },
                ),
              ),
              IconButton(
                tooltip: 'Remove ${b['name']}',
                onPressed: () => _remove(id),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          // What this barangay will ask for, one chip per item.
          if (preview != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 48),
              child: Wrap(
                key: ValueKey('preview-$id'),
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final part in preview.split(' · '))
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: cs.primaryContainer.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Text(
                        part,
                        style: t.bodySmall?.copyWith(
                          color: cs.onPrimaryContainer,
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The checklist behind "Affected barangays": search, select all (or all
/// prone), one checkbox per barangay. Returns the picked ids, or null.
class _BarangayChecklist extends StatefulWidget {
  final List<Map<String, dynamic>> barangays;
  final Set<String> prone; // empty = general type, no tags
  final String typeName;
  final Set<String> initial;
  const _BarangayChecklist({
    required this.barangays,
    required this.prone,
    required this.typeName,
    required this.initial,
  });

  @override
  State<_BarangayChecklist> createState() => _BarangayChecklistState();
}

class _BarangayChecklistState extends State<_BarangayChecklist> {
  late final Set<String> picked = {...widget.initial};
  String query = '';

  bool get _tagged => widget.prone.isNotEmpty;

  /// What "Select all" picks: every barangay, or every prone one.
  Set<String> get _allIds => {
    for (final b in widget.barangays)
      if (!_tagged || widget.prone.contains('${b['id']}')) '${b['id']}',
  };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final shown = [
      for (final b in widget.barangays)
        if ('${b['name']}'.toLowerCase().contains(query.toLowerCase())) b,
    ];
    final allIds = _allIds;
    final allOn = allIds.isNotEmpty && picked.containsAll(allIds);
    return AlertDialog(
      title: const Text('Affected barangays'),
      contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      content: SizedBox(
        width: 420,
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: Column(
          children: [
            TextField(
              key: const ValueKey('barangay-search'),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search barangay',
                isDense: true,
              ),
              onChanged: (v) => setState(() => query = v.trim()),
            ),
            CheckboxListTile(
              key: const ValueKey('select-all'),
              value: allOn,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(
                _tagged ? 'Select all prone barangays' : 'Select all barangays',
                style: t.titleSmall,
              ),
              subtitle: Text('${allIds.length} barangays'),
              onChanged: (on) => setState(() {
                if (on == true) {
                  picked.addAll(allIds);
                } else {
                  picked.removeAll(allIds);
                }
              }),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                children: [
                  for (final b in shown)
                    CheckboxListTile(
                      key: ValueKey('check-${b['id']}'),
                      dense: true,
                      value: picked.contains('${b['id']}'),
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text('${b['name']}'),
                      subtitle: !_tagged
                          ? null
                          : widget.prone.contains('${b['id']}')
                          ? Text(
                              'Prone to ${widget.typeName}',
                              style: TextStyle(color: cs.primary),
                            )
                          : const Text('Not tagged'),
                      onChanged: (on) => setState(() {
                        if (on == true) {
                          picked.add('${b['id']}');
                        } else {
                          picked.remove('${b['id']}');
                        }
                      }),
                    ),
                  if (shown.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(Space.md),
                      child: Text('No barangay matches.'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('add-barangays'),
          onPressed: () => Navigator.pop(context, picked),
          child: Text(
            picked.isEmpty ? 'Done' : 'Done (${picked.length} selected)',
          ),
        ),
      ],
    );
  }
}
