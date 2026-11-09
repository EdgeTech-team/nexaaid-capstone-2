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

/// The barangay part of the form in "Several barangays" mode: chips to pick
/// barangays (prone ones first and tagged for a location-specific type,
/// NF-004 soft warning kept), an "All barangays" shortcut, and one
/// "Affected families" field per picked barangay. A barangay left blank or
/// at 0 is not submitted.
class MultiBarangayPicker extends StatefulWidget {
  final Names names;
  final String? typeId;
  final BarangayRows rows;
  final VoidCallback onChanged;
  final int maxFamilies;
  const MultiBarangayPicker({
    super.key,
    required this.names,
    required this.typeId,
    required this.rows,
    required this.onChanged,
    required this.maxFamilies,
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

  void _add(String id) {
    widget.rows.putIfAbsent(id, TextEditingController.new);
    widget.onChanged();
  }

  void _remove(String id) {
    widget.rows.remove(id)?.dispose();
    widget.onChanged();
  }

  void _addAll(Iterable<String> ids) {
    for (final id in ids) {
      widget.rows.putIfAbsent(id, TextEditingController.new);
    }
    widget.onChanged();
  }

  void _clear() {
    for (final c in widget.rows.values) {
      c.dispose();
    }
    widget.rows.clear();
    widget.onChanged();
  }

  Future<void> _pick(String id, Set<String> prone) async {
    if (!_locationSpecific || prone.isEmpty || prone.contains(id)) {
      _add(id);
      return;
    }
    final name = widget.names.of('barangays', id);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Barangay not tagged'),
        content: Text('$name is not tagged as prone to $_typeName. Continue?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Choose another'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) _add(id);
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
    final all = widget.names.rows('barangays')
      ..sort((a, b) {
        final pa = prone.contains('${a['id']}') ? 0 : 1;
        final pb = prone.contains('${b['id']}') ? 0 : 1;
        return pa != pb ? pa - pb : '${a['name']}'.compareTo('${b['name']}');
      });
    final tagged = _locationSpecific && prone.isNotEmpty;
    final picked = [
      for (final b in all)
        if (widget.rows.containsKey('${b['id']}')) b,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          tagged
              ? 'Affected barangays. Barangays prone to $_typeName come first.'
              : 'Affected barangays',
          style: t.titleSmall,
        ),
        Gaps.v8,
        Wrap(
          spacing: Space.xs,
          runSpacing: Space.xs,
          children: [
            ActionChip(
              key: const ValueKey('all-barangays'),
              avatar: const Icon(Icons.select_all, size: 18),
              label: Text(tagged ? 'All prone barangays' : 'All barangays'),
              onPressed: () => _addAll([
                for (final b in all)
                  if (!tagged || prone.contains('${b['id']}')) '${b['id']}',
              ]),
            ),
            if (widget.rows.isNotEmpty)
              ActionChip(
                avatar: const Icon(Icons.clear_all, size: 18),
                label: const Text('Clear'),
                onPressed: _clear,
              ),
          ],
        ),
        Gaps.v8,
        Wrap(
          spacing: Space.xs,
          runSpacing: Space.xs,
          children: [
            for (final b in all)
              FilterChip(
                key: ValueKey('brgy-chip-${b['id']}'),
                label: Text(
                  tagged && prone.contains('${b['id']}')
                      ? '${b['name']} · prone'
                      : '${b['name']}',
                ),
                selected: widget.rows.containsKey('${b['id']}'),
                onSelected: (on) =>
                    on ? _pick('${b['id']}', prone) : _remove('${b['id']}'),
              ),
          ],
        ),
        if (picked.isNotEmpty) ...[
          Gaps.v16,
          Text('Affected families per barangay', style: t.titleSmall),
          Text(
            'Leave a barangay blank to skip it. Each one becomes its own '
            'report.',
            style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          Gaps.v8,
          for (final b in picked)
            Padding(
              key: ValueKey('fam-row-${b['id']}'),
              padding: const EdgeInsets.only(bottom: Space.xs),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Text('${b['name']}', style: t.bodyLarge),
                  ),
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      key: ValueKey('families-${b['id']}'),
                      controller: widget.rows['${b['id']}'],
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
                    onPressed: () => _remove('${b['id']}'),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}
