import 'package:flutter/material.dart';

import '../api.dart';
import '../design/design.dart';

// ---------------------------------------------------------------------------
// Shared report filters for every screen that lists reports: Report Status,
// Report Validation and Validated Reports.
//
// UAT Nov 2026 (M2.3, M2.5, M3.3): one Filter button opens a panel under it
// (not full screen) with Validation Status, Priorities and Fulfillment
// Status, then Clear and Apply. Active filters show as small chips that can
// be removed one by one, and the sort is a compact menu.
//
// Status and priority are filtered by the server (the screens send them as
// query parameters); fulfillment status and sorting are worked out in the
// app on the rows already loaded.
// ---------------------------------------------------------------------------

/// fulfillment_percentage as a number, or null if the row has none. The
/// staff report endpoints send it as text ("40.00", a Decimal); /lookups
/// sends a number, so both are accepted.
double? fulfillmentPercent(Map r) {
  final p = r['fulfillment_percentage'];
  if (p == null) return null;
  if (p is num) return p.toDouble();
  return double.tryParse('$p');
}

/// Fulfillment status of a report from its fulfillment_percentage.
/// Returns null when the row has no fulfillment data.
String? fulfillmentState(Map r) {
  final pct = fulfillmentPercent(r);
  if (pct == null) return null;
  if (pct >= 100) return 'Fulfilled';
  if (pct > 0) return 'In Progress';
  return 'Not Started';
}

const fulfillmentStates = ['Not Started', 'In Progress', 'Fulfilled'];

/// Report statuses, exactly as the backend stores them
/// (models/report.py, disaster_reports.status).
const reportStatuses = ['Pending', 'Validated', 'Rejected', 'Cancelled'];

/// Priority levels for Appendix H 3.3 priority-based report filtering.
const priorityLevels = ['Critical', 'High', 'Medium', 'Low', 'Needs Review'];

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
  double pct(Map r) => fulfillmentPercent(r) ?? 0;
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

/// What a report list shows: the three filters of the Filter panel (null =
/// all), the sort, and "Only my reports" (Report Status, Disaster Unit).
@immutable
class ReportView {
  final String? status;
  final String? priority;
  final String? fulfillment;
  final ReportSort sort;
  final bool onlyMine;

  const ReportView({
    this.status,
    this.priority,
    this.fulfillment,
    this.sort = ReportSort.urgent,
    this.onlyMine = false,
  });

  /// These three filters (the ones left out are "all"), same sort and
  /// "Only my reports".
  ReportView withFilters({
    String? status,
    String? priority,
    String? fulfillment,
  }) => ReportView(
    status: status,
    priority: priority,
    fulfillment: fulfillment,
    sort: sort,
    onlyMine: onlyMine,
  );

  ReportView withSort(ReportSort s) => ReportView(
    status: status,
    priority: priority,
    fulfillment: fulfillment,
    sort: s,
    onlyMine: onlyMine,
  );

  ReportView withOnlyMine(bool v) => ReportView(
    status: status,
    priority: priority,
    fulfillment: fulfillment,
    sort: sort,
    onlyMine: v,
  );
}

/// How many of the panel's filters differ from [defaults] (the number on
/// the Filter button).
int activeFilters(ReportView v, [ReportView defaults = const ReportView()]) =>
    (v.status != defaults.status ? 1 : 0) +
    (v.priority != null ? 1 : 0) +
    (v.fulfillment != null ? 1 : 0);

/// UAT Nov 2026, option A: each report list keeps its filters and sort while
/// the app is open, so leaving the tab and coming back shows the same view.
/// Nothing is saved on the device: closing the app, refreshing the web page
/// or logging out starts again from the defaults. A new login has a new
/// token, so the next account never gets the previous one's filters.
abstract final class ReportViewMemory {
  static final _views = <String, ReportView>{};
  static String? _session;

  static ReportView read(String list, ReportView defaults) =>
      _forSession()[list] ?? defaults;

  static void write(String list, ReportView view) => _forSession()[list] = view;

  /// Forget every list's filters (tests).
  @visibleForTesting
  static void clear() => _views.clear();

  static Map<String, ReportView> _forSession() {
    final token = Api.instance.token;
    if (token != _session) {
      _views.clear();
      _session = token;
    }
    return _views;
  }
}

/// The Filter button (with the number of filters on), the compact sort
/// menu, and a removable chip for each filter that is on.
class ReportFilterBar extends StatelessWidget {
  final ReportView value;
  final ValueChanged<ReportView> onChanged;

  /// What Clear goes back to. Sort and "Only my reports" are kept.
  final ReportView defaults;

  /// Validation Status choices; null = no such section.
  final List<String>? statuses;

  /// "All" is a choice in Validation Status. false = a status must be
  /// picked (Report Validation always shows one list).
  final bool anyStatus;

  /// Show the Priorities section (Appendix H 3.3 roles).
  final bool priorities;

  /// The rows loaded now, for counts like "Not Started (9)".
  final List<Map> rows;

  /// Priorities and Fulfillment Status only work with this status
  /// (Report Validation: 'Validated'); null = always.
  final String? detailsOnlyFor;

  final bool showSort;

  /// More controls after the buttons, e.g. "Only my reports".
  final List<Widget> trailing;

  const ReportFilterBar({
    super.key,
    required this.value,
    required this.onChanged,
    this.defaults = const ReportView(),
    this.statuses,
    this.anyStatus = true,
    this.priorities = true,
    this.rows = const [],
    this.detailsOnlyFor,
    this.showSort = true,
    this.trailing = const [],
  });

  /// Priorities and fulfillment only where they apply ([detailsOnlyFor]).
  ReportView _usable(ReportView v) =>
      detailsOnlyFor == null || v.status == detailsOnlyFor
      ? v
      : v.withFilters(status: v.status);

  List<Widget> _chips() {
    final v = value;
    Widget chip(String label, Color dot, ReportView? without) => InputChip(
      avatar: Icon(Icons.circle, size: 10, color: dot),
      label: Text(label),
      visualDensity: VisualDensity.compact,
      onDeleted: without == null ? null : () => onChanged(_usable(without)),
      deleteButtonTooltipMessage: 'Remove $label',
    );
    return [
      if (v.status != null)
        chip(
          v.status!,
          StatusColors.base(v.status),
          // The status a screen always shows (Pending) cannot be removed.
          v.status == defaults.status
              ? null
              : v.withFilters(
                  status: defaults.status,
                  priority: v.priority,
                  fulfillment: v.fulfillment,
                ),
        ),
      if (v.priority != null)
        chip(
          v.priority!,
          PriorityColors.base(v.priority),
          v.withFilters(status: v.status, fulfillment: v.fulfillment),
        ),
      if (v.fulfillment != null)
        chip(
          v.fulfillment!,
          StatusColors.base(v.fulfillment),
          v.withFilters(status: v.status, priority: v.priority),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final chips = _chips();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: Space.xs,
          runSpacing: Space.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _FilterButton(this),
            if (showSort)
              ReportSortMenu(
                value: value.sort,
                onChanged: (s) => onChanged(value.withSort(s)),
              ),
            ...trailing,
          ],
        ),
        if (chips.isNotEmpty) ...[
          Gaps.v8,
          Wrap(spacing: Space.xs, runSpacing: Space.xs, children: chips),
        ],
      ],
    );
  }
}

class _FilterButton extends StatefulWidget {
  final ReportFilterBar bar;
  const _FilterButton(this.bar);

  @override
  State<_FilterButton> createState() => _FilterButtonState();
}

class _FilterButtonState extends State<_FilterButton> {
  final _menu = MenuController();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final n = activeFilters(widget.bar.value, widget.bar.defaults);
    return MenuAnchor(
      controller: _menu,
      alignmentOffset: const Offset(0, Space.xxs),
      menuChildren: [_FilterPanel(widget.bar, close: _menu.close)],
      builder: (context, menu, _) => Badge(
        isLabelVisible: n > 0,
        label: Text('$n'),
        backgroundColor: cs.primary,
        textColor: cs.onPrimary,
        child: OutlinedButton.icon(
          onPressed: () => menu.isOpen ? menu.close() : menu.open(),
          icon: const Icon(Icons.filter_list),
          label: const Text('Filter'),
        ),
      ),
    );
  }
}

/// The panel under the Filter button. Choices change a draft; Apply uses
/// it, Clear goes back to the defaults.
class _FilterPanel extends StatefulWidget {
  final ReportFilterBar bar;
  final VoidCallback close;
  const _FilterPanel(this.bar, {required this.close});

  @override
  State<_FilterPanel> createState() => _FilterPanelState();
}

class _FilterPanelState extends State<_FilterPanel> {
  late ReportView draft = widget.bar.value;

  void _pick({
    required String? status,
    required String? priority,
    required String? fulfillment,
  }) => setState(
    () => draft = draft.withFilters(
      status: status,
      priority: priority,
      fulfillment: fulfillment,
    ),
  );

  void _done(ReportView v) {
    widget.bar.onChanged(widget.bar._usable(v));
    widget.close();
  }

  @override
  Widget build(BuildContext context) {
    final bar = widget.bar;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final d = draft;
    final details =
        bar.detailsOnlyFor == null || d.status == bar.detailsOnlyFor;
    final note = details ? null : 'Only for ${bar.detailsOnlyFor} reports';
    int count(String s) =>
        bar.rows.where((r) => fulfillmentState(r) == s).length;

    Widget choice(
      String label,
      bool selected,
      VoidCallback? onTap, [
      Color? dot,
    ]) => ChoiceChip(
      avatar: dot == null ? null : Icon(Icons.circle, size: 10, color: dot),
      label: Text(label),
      selected: selected,
      onSelected: onTap == null ? null : (_) => onTap(),
    );

    Widget section(String title, List<Widget> choices, {String? note}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: Space.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: t.titleSmall),
              if (note != null)
                Text(
                  note,
                  style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              Gaps.v8,
              Wrap(spacing: Space.xs, runSpacing: Space.xs, children: choices),
            ],
          ),
        );

    return SizedBox(
      // Under the button, never wider than the screen (phones, web).
      width: (MediaQuery.sizeOf(context).width - 2 * Space.md).clamp(
        240.0,
        360.0,
      ),
      child: Padding(
        padding: const EdgeInsets.all(Space.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (bar.statuses != null)
              section('Validation Status', [
                if (bar.anyStatus)
                  choice(
                    'All',
                    d.status == null,
                    () => _pick(
                      status: null,
                      priority: d.priority,
                      fulfillment: d.fulfillment,
                    ),
                  ),
                for (final s in bar.statuses!)
                  choice(
                    s,
                    d.status == s,
                    () => _pick(
                      status: s,
                      priority: d.priority,
                      fulfillment: d.fulfillment,
                    ),
                    StatusColors.base(s),
                  ),
              ]),
            if (bar.priorities)
              section('Priorities', [
                choice(
                  'All priorities',
                  d.priority == null,
                  details
                      ? () => _pick(
                          status: d.status,
                          priority: null,
                          fulfillment: d.fulfillment,
                        )
                      : null,
                ),
                for (final p in priorityLevels)
                  choice(
                    p,
                    d.priority == p,
                    details
                        ? () => _pick(
                            status: d.status,
                            priority: p,
                            fulfillment: d.fulfillment,
                          )
                        : null,
                    PriorityColors.base(p),
                  ),
              ], note: note),
            section('Fulfillment Status', [
              choice(
                'Any progress',
                d.fulfillment == null,
                details
                    ? () => _pick(
                        status: d.status,
                        priority: d.priority,
                        fulfillment: null,
                      )
                    : null,
              ),
              for (final s in fulfillmentStates)
                choice(
                  '$s (${count(s)})',
                  d.fulfillment == s,
                  details
                      ? () => _pick(
                          status: d.status,
                          priority: d.priority,
                          fulfillment: s,
                        )
                      : null,
                  StatusColors.base(s),
                ),
            ], note: note),
            Row(
              children: [
                TextButton(
                  onPressed: () =>
                      _done(bar.value.withFilters(status: bar.defaults.status)),
                  child: const Text('Clear'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () => _done(d),
                  child: const Text('Apply'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact sort menu under its button (UAT Nov 2026: the old "Sort by"
/// field opened full screen on phones). Same options and default.
class ReportSortMenu extends StatelessWidget {
  final ReportSort value;
  final ValueChanged<ReportSort> onChanged;
  const ReportSortMenu({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => MenuAnchor(
    alignmentOffset: const Offset(0, Space.xxs),
    menuChildren: [
      for (final s in ReportSort.values)
        MenuItemButton(
          leadingIcon: Icon(s == value ? Icons.check : null, size: 18),
          onPressed: () => onChanged(s),
          child: Text(s.label),
        ),
    ],
    builder: (context, menu, _) => OutlinedButton.icon(
      onPressed: () => menu.isOpen ? menu.close() : menu.open(),
      icon: const Icon(Icons.sort),
      label: Text('Sort: ${value.label}'),
    ),
  );
}

/// Empty list. When filters are hiding reports it says so and offers Clear
/// filters, so reports never seem to have disappeared.
class ReportListEmpty extends StatelessWidget {
  final String text;
  final bool filtered;
  final VoidCallback onClear;
  const ReportListEmpty(
    this.text, {
    super.key,
    required this.filtered,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) => filtered
      ? EmptyView(
          compact: true,
          icon: Icons.filter_alt_off_outlined,
          title: 'No reports match these filters.',
          message: 'Clear the filters to see every report.',
          action: TextButton(
            onPressed: onClear,
            child: const Text('Clear filters'),
          ),
        )
      : EmptyView(compact: true, title: text);
}
