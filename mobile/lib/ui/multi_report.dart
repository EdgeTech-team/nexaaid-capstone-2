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

/// A per-family amount as typed ("6", "0.2", "1.25") in hundredths
/// (600, 20, 125). Null when it is not a number above 0 with at most two
/// decimals. Whole hundredths keep the rounding exact (no 0.1 + 0.2 issues).
int? perFamilyHundredths(String text) {
  final m = RegExp(r'^(\d{1,7})(?:\.(\d{1,2}))?$').firstMatch(text.trim());
  if (m == null) return null;
  final whole = int.parse(m.group(1)!);
  final frac = int.parse((m.group(2) ?? '').padRight(2, '0'));
  final value = whole * 100 + frac;
  return value > 0 ? value : null;
}

/// One barangay's amount: ceil(families x per-family). 40 x 0.2 = 8,
/// 41 x 0.2 = 8.2 -> 9.
int barangayQuantity(int families, int hundredths) =>
    (families * hundredths + 99) ~/ 100;

/// A per-family amount from the server (6, 0.1, 0.25) in hundredths.
int hundredthsOf(num value) => (value * 100).round();

/// "1,440" (thousands separators for the totals).
String withCommas(int n) =>
    n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

/// 6 -> "6", 0.1 -> "0.1", 0.25 -> "0.25" (template amounts in the form).
String formatPerFamily(num value) {
  final hundredths = (value * 100).round();
  final whole = hundredths ~/ 100;
  final frac = hundredths % 100;
  if (frac == 0) return '$whole';
  return frac % 10 == 0
      ? '$whole.${frac ~/ 10}'
      : '$whole.${'$frac'.padLeft(2, '0')}';
}

/// Validator of the "Per family" field.
String? perFamilyError(String? v) {
  if ((v ?? '').trim().isEmpty) return 'Enter an amount per family';
  return perFamilyHundredths(v!) == null
      ? 'A number above 0, up to 2 decimals (e.g. 0.5)'
      : null;
}

/// Typing filter for the "Per family" field: digits and one dot.
final perFamilyInput = <TextInputFormatter>[
  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
  LengthLimitingTextInputFormatter(10),
];

/// The barangays of the form, with what was typed for each:
/// barangay id -> affected families field.
typedef BarangayRows = Map<String, TextEditingController>;

/// One barangay's totals as a short line, e.g. "Rice 720 kg · Water 2,400 L"
/// (null = nothing to show yet). Given by the report form.
typedef BarangayPreview = String? Function(int families);

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
            Text('Affected families per barangay', style: t.titleSmall),
            Text(
              'Leave a barangay blank to skip it.',
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            Gaps.v8,
            for (final b in picked) _row(b, prone),
          ],
        ],
      ),
    );
  }

  Widget _row(Map b, Set<String> prone) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final id = '${b['id']}';
    final controller = widget.rows[id]!;
    final families = int.tryParse(controller.text.trim()) ?? 0;
    final preview = families > 0 ? widget.preview?.call(families) : null;
    final untagged =
        _locationSpecific && prone.isNotEmpty && !prone.contains(id);
    return Padding(
      key: ValueKey('fam-row-$id'),
      padding: const EdgeInsets.only(bottom: Space.xs),
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
                    Text('${b['name']}', style: t.bodyLarge),
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
          if (preview != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 48),
              child: Text(
                preview,
                key: ValueKey('preview-$id'),
                style: t.bodySmall?.copyWith(color: cs.primary),
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
