import 'package:flutter/material.dart';

import '../design/design.dart';

// ---------------------------------------------------------------------------
// Shared report filters for every dashboard that lists reports: fulfillment
// status (replaces a separate "Done" section: fulfilled reports are found
// with the Fulfilled chip) and sorting. Filtering is on the rows already
// loaded, so no backend change is needed.
// ---------------------------------------------------------------------------

/// Fulfillment status of a report from its fulfillment_percentage.
/// Returns null when the row has no fulfillment data.
String? fulfillmentState(Map r) {
  final p = r['fulfillment_percentage'];
  if (p == null) return null;
  final pct = (p as num).toDouble();
  if (pct >= 100) return 'Fulfilled';
  if (pct > 0) return 'In Progress';
  return 'Not Started';
}

const fulfillmentStates = ['Not Started', 'In Progress', 'Fulfilled'];

enum ReportSort {
  urgent('Most urgent'),
  leastFulfilled('Least fulfilled'),
  mostFulfilled('Most fulfilled'),
  mostFamilies('Most families affected'),
  newest('Newest first');

  final String label;
  const ReportSort(this.label);
}

/// Filters by fulfillment status (null = all) and sorts. [id] reads a
/// report's id (it is "id" in lookups and "report_id" elsewhere).
List<Map<String, dynamic>> sortAndFilterReports(
  Iterable<Map<String, dynamic>> rows, {
  String? fulfillment,
  ReportSort sort = ReportSort.urgent,
}) {
  double pct(Map r) =>
      (r['fulfillment_percentage'] as num?)?.toDouble() ?? 0;
  int id(Map r) => ((r['report_id'] ?? r['id'] ?? 0) as num).toInt();
  int fam(Map r) => (r['affected_families'] as num?)?.toInt() ?? 0;
  int done(Map r) => pct(r) >= 100 ? 1 : 0;

  final list = rows
      .where((r) => fulfillment == null || fulfillmentState(r) == fulfillment)
      .toList();
  list.sort(switch (sort) {
    // Open reports first, then priority, then least fulfilled.
    ReportSort.urgent => (a, b) {
      final d = done(a).compareTo(done(b));
      if (d != 0) return d;
      final p = PriorityColors.rank(a['priority_level'] as String?)
          .compareTo(PriorityColors.rank(b['priority_level'] as String?));
      return p != 0 ? p : pct(a).compareTo(pct(b));
    },
    ReportSort.leastFulfilled => (a, b) => pct(a).compareTo(pct(b)),
    ReportSort.mostFulfilled => (a, b) => pct(b).compareTo(pct(a)),
    ReportSort.mostFamilies => (a, b) => fam(b).compareTo(fam(a)),
    ReportSort.newest => (a, b) => id(b).compareTo(id(a)),
  });
  return list;
}

/// "All · Not Started · In Progress · Fulfilled" chips with counts.
class FulfillmentChips extends StatelessWidget {
  final List<Map> rows;
  final String? value;
  final ValueChanged<String?> onChanged;

  const FulfillmentChips({
    super.key,
    required this.rows,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    int count(String s) => rows.where((r) => fulfillmentState(r) == s).length;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final s in <String?>[null, ...fulfillmentStates])
            Padding(
              padding: const EdgeInsets.only(right: Space.xs),
              child: ChoiceChip(
                avatar: s == null
                    ? null
                    : Icon(Icons.circle, size: 10, color: StatusColors.base(s)),
                label: Text(
                  s == null ? 'Any progress' : '$s (${count(s)})',
                ),
                selected: value == s,
                onSelected: (_) => onChanged(s),
              ),
            ),
        ],
      ),
    );
  }
}

/// Sort dropdown used next to the report filters.
class ReportSortField extends StatelessWidget {
  final ReportSort value;
  final ValueChanged<ReportSort> onChanged;
  const ReportSortField({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<ReportSort>(
    initialValue: value,
    isExpanded: true,
    decoration: const InputDecoration(
      labelText: 'Sort by',
      prefixIcon: Icon(Icons.sort),
      isDense: true,
    ),
    items: [
      for (final s in ReportSort.values)
        DropdownMenuItem(value: s, child: Text(s.label)),
    ],
    onChanged: (v) => onChanged(v ?? value),
  );
}
