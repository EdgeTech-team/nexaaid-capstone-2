import 'package:flutter/material.dart';

import 'disaster_art.dart';
import 'report_filters.dart';
import 'report_summary_card.dart' show NeedChips;
import 'widgets.dart';
import 'donate_screen.dart';
export 'donate_screen.dart' show DonateScreen, DonationReceipt;
import 'needs_progress.dart';

/// Ivan's note #2: the signed-in donor / relief organization's middle tab.
/// It shows every validated report, active and done, in one list. There is
/// no separate Done section (Ivan's note): fulfilled reports are found with
/// the "Fulfilled" progress chip or by sorting. Reports stay "Validated"
/// after they are fulfilled, so the list comes from GET /lookups
/// `validated_reports`.
class DonorReportsTab extends StatelessWidget {
  const DonorReportsTab({super.key});

  @override
  Widget build(BuildContext context) => const ReportsFeed();
}

/// UC-D2 / UC-R2 step 1-3: browse validated reports and pick one to
/// support. Layout follows Ivan's Oct 18 "All Reports" mockup.
///
/// [done]: null shows every validated report (guests); false only the ones
/// still under 100%; true only the fulfilled ones, without Donate buttons.
class ReportsFeed extends StatefulWidget {
  final bool? done;
  const ReportsFeed({super.key, this.done});

  @override
  State<ReportsFeed> createState() => _ReportsFeedState();
}

/// Quick filters at the top of the list.
enum _Quick { all, urgent, needs, fulfilled }

class _ReportsFeedState extends State<ReportsFeed> {
  // Ivan (Oct 18 mockup): search, quick chips, barangay + "More filters"
  // (bottom sheet), active filters as removable chips, count + sort, and
  // compact cards with a picture and "View details".
  final _searchC = TextEditingController();
  String search = '';
  String? barangay, type, priority;
  _Quick quick = _Quick.all;
  ReportSort sort = ReportSort.urgent;

  @override
  void dispose() {
    _searchC.dispose();
    super.dispose();
  }

  static const _priorities = ['Critical', 'High', 'Medium', 'Low'];

  bool get _anyFilter =>
      search.isNotEmpty ||
      barangay != null ||
      type != null ||
      priority != null ||
      quick != _Quick.all;

  void _resetFilters() => setState(() {
    _searchC.clear();
    search = '';
    barangay = type = priority = null;
    quick = _Quick.all;
  });

  /// Number of filters inside the "More filters" sheet that are on.
  int get _sheetCount => [type, priority].where((v) => v != null).length;

  Future<void> _moreFilters(Names names) async {
    final result = await showModalBottomSheet<(String?, String?)>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _MoreFiltersSheet(
        types: [for (final t in names.rows('disaster_types')) '${t['name']}'],
        priorities: _priorities,
        type: type,
        priority: priority,
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      type = result.$1;
      priority = result.$2;
      // A priority picked here replaces the Urgent shortcut.
      if (priority != null && quick == _Quick.urgent) quick = _Quick.all;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [api.lookupsResult],
      builder: (context, data) {
        final names = Names(Map<String, dynamic>.from(data[0] as Map));
        final done = widget.done;
        final cs = Theme.of(context).colorScheme;
        final t = Theme.of(context).textTheme;
        final all = names.rows('validated_reports').where((r) {
          if (done == null) return true;
          final full = (fulfillmentPercent(r) ?? 0) >= 100;
          return done ? full : !full;
        }).toList();
        final q = search.toLowerCase();
        bool quickOk(Map r) {
          final pct = fulfillmentPercent(r) ?? 0;
          return switch (quick) {
            _Quick.all => true,
            _Quick.urgent =>
              r['priority_level'] == 'Critical' ||
                  r['priority_level'] == 'High',
            _Quick.needs => pct < 100,
            _Quick.fulfilled => pct >= 100,
          };
        }

        final matching = all.where((r) {
          final text = [
            r['barangay'],
            r['sitio'],
            r['disaster'],
            r['assistance_needed'],
            r['description'],
          ].join(' ').toLowerCase();
          return (q.isEmpty || text.contains(q)) &&
              (barangay == null || r['barangay'] == barangay) &&
              (type == null || r['disaster'] == type) &&
              (priority == null || r['priority_level'] == priority) &&
              quickOk(r);
        }).toList();
        final reports = sortAndFilterReports(matching, sort: sort);

        // Active filters, shown as chips that can be removed one by one.
        final active = <(String, IconData, VoidCallback)>[
          if (quick == _Quick.urgent)
            ('Urgent', Icons.warning_amber_rounded,
                () => setState(() => quick = _Quick.all)),
          if (quick == _Quick.needs)
            ('Needs assistance', Icons.volunteer_activism_outlined,
                () => setState(() => quick = _Quick.all)),
          if (quick == _Quick.fulfilled)
            ('Fulfilled', Icons.check_circle_outline,
                () => setState(() => quick = _Quick.all)),
          if (barangay != null)
            (barangay!, Icons.place_outlined,
                () => setState(() => barangay = null)),
          if (type != null)
            (type!, Icons.flood_outlined, () => setState(() => type = null)),
          if (priority != null)
            (priority!, Icons.flag_outlined,
                () => setState(() => priority = null)),
        ];

        Widget quickChip(_Quick value, String label, IconData icon, Color c) =>
            Padding(
              padding: const EdgeInsets.only(right: Space.xs),
              child: ChoiceChip(
                avatar: Icon(icon, size: 18, color: c),
                label: Text(label),
                selected: quick == value,
                showCheckmark: false,
                onSelected: (_) => setState(() {
                  quick = value;
                  // Urgent is a priority shortcut: it replaces a priority
                  // picked in More filters.
                  if (value == _Quick.urgent) priority = null;
                }),
              ),
            );

        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            PageHeader(
              done == null
                  ? 'All Reports'
                  : done
                  ? 'Completed Reports'
                  : 'Active Reports',
              subtitle: done == null
                  ? 'Find communities that need assistance.'
                  : done
                  ? 'Reports that received everything they needed. '
                        'Thank you to everyone who helped.'
                  : 'Reports that still need help. Pick one and pledge '
                        'goods.',
            ),
            // Kept from the old screen (Ivan): the two summary cards.
            // Tapping one shows those reports.
            StatCardGrid([
              StatCard(
                label: done == null
                    ? 'Validated reports'
                    : done
                    ? 'Completed reports'
                    : 'Active reports',
                value: '${all.length}',
                icon: done == true
                    ? Icons.task_alt_outlined
                    : Icons.report_outlined,
                onTap: done == null ? _resetFilters : null,
              ),
              if (done != true)
                StatCard(
                  label: 'High / critical priority',
                  value:
                      '${all.where((r) => r['priority_level'] == 'High' || r['priority_level'] == 'Critical').length}',
                  icon: Icons.trending_up,
                  color: PriorityColors.base('High'),
                  onTap: done == null
                      ? () => setState(() {
                          quick = _Quick.urgent;
                          priority = null;
                        })
                      : null,
                ),
            ]),
            Gaps.v12,
            TextField(
              controller: _searchC,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Search by barangay or need...',
                suffixIcon: search.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() {
                          _searchC.clear();
                          search = '';
                        }),
                      ),
              ),
              onChanged: (v) => setState(() => search = v.trim()),
            ),
            if (done == null) ...[
              Gaps.v12,
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    quickChip(_Quick.all, 'All', Icons.apps, cs.primary),
                    quickChip(
                      _Quick.urgent,
                      'Urgent',
                      Icons.warning_amber_rounded,
                      PriorityColors.base('Critical'),
                    ),
                    quickChip(
                      _Quick.needs,
                      'Needs assistance',
                      Icons.volunteer_activism_outlined,
                      cs.primary,
                    ),
                    quickChip(
                      _Quick.fulfilled,
                      'Fulfilled',
                      Icons.check_circle_outline,
                      StatusColors.base('Fulfilled'),
                    ),
                  ],
                ),
              ),
            ],
            Gaps.v12,
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('brgy-$barangay'),
                    initialValue: barangay,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      isDense: true,
                      prefixIcon: Icon(Icons.place_outlined, size: 20),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                    items: [
                      const DropdownMenuItem<String>(
                        value: null,
                        child: Text('All barangays'),
                      ),
                      for (final b in names.rows('barangays'))
                        DropdownMenuItem(
                          value: '${b['name']}',
                          child: Text('${b['name']}'),
                        ),
                    ],
                    onChanged: (v) => setState(() => barangay = v),
                  ),
                ),
                Gaps.h8,
                // Small phones (under 360 px): the icon only, so the
                // barangay dropdown keeps its room.
                if (MediaQuery.sizeOf(context).width < 360)
                  IconButton.outlined(
                    tooltip: 'More filters',
                    onPressed: () => _moreFilters(names),
                    style: IconButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    icon: Badge(
                      isLabelVisible: _sheetCount > 0,
                      label: Text('$_sheetCount'),
                      child: const Icon(Icons.tune),
                    ),
                  )
                else
                  OutlinedButton.icon(
                    onPressed: () => _moreFilters(names),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                    ),
                    icon: Badge(
                      isLabelVisible: _sheetCount > 0,
                      label: Text('$_sheetCount'),
                      child: const Icon(Icons.tune),
                    ),
                    label: const Text('More filters'),
                  ),
              ],
            ),
            if (active.isNotEmpty) ...[
              Gaps.v12,
              Wrap(
                spacing: Space.xs,
                runSpacing: Space.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final (label, icon, remove) in active)
                    InputChip(
                      avatar: Icon(icon, size: 18),
                      label: Text(label),
                      onDeleted: remove,
                      deleteButtonTooltipMessage: 'Remove $label',
                    ),
                  TextButton.icon(
                    onPressed: _resetFilters,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Clear all'),
                  ),
                ],
              ),
            ],
            Gaps.v12,
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${reports.length} '
                    '${reports.length == 1 ? 'report' : 'reports'} found',
                    style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
                PopupMenuButton<ReportSort>(
                  tooltip: 'Sort reports',
                  initialValue: sort,
                  onSelected: (v) => setState(() => sort = v),
                  itemBuilder: (_) => [
                    for (final s in ReportSort.values)
                      PopupMenuItem(value: s, child: Text(s.label)),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Sort: ${sort.label}',
                          style: t.labelLarge?.copyWith(color: cs.primary),
                        ),
                        Icon(Icons.arrow_drop_down, color: cs.primary),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            Gaps.v8,
            if (reports.isEmpty)
              _NoReports(
                message: all.isEmpty
                    ? (done == true
                          ? 'No completed reports yet.'
                          : 'When the City validates a disaster report, it '
                                'shows up here.')
                    : 'Try adjusting your search or filters to find more '
                          'reports.',
                onReset: _anyFilter ? _resetFilters : null,
              ),
            for (final r in reports)
              _ReportListCard(
                report: r,
                onDetails: () => _showDetails(context, r, names),
                // A fulfilled report has what it needs: no Donate button.
                onDonate:
                    widget.done == true || (fulfillmentPercent(r) ?? 0) >= 100
                    ? null
                    : () => _donate(r, names),
              ),
          ],
        );
      },
    );
  }

  void _donate(Map<String, dynamic> r, Names names) =>
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => DonateScreen(report: r, names: names),
        ),
      );

  /// "Details": the whole report in a bottom sheet, with Donate.
  void _showDetails(BuildContext context, Map<String, dynamic> r, Names names) {
    final canDonate =
        widget.done != true && (fulfillmentPercent(r) ?? 0) < 100;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        final t = Theme.of(ctx).textTheme;
        final cs = Theme.of(ctx).colorScheme;
        Widget row(IconData icon, String text) => Padding(
          padding: const EdgeInsets.only(bottom: Space.xs),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: cs.onSurfaceVariant),
              Gaps.h8,
              Expanded(child: Text(text, style: t.bodyMedium)),
            ],
          ),
        );
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DisasterArt(
                  disasterKind(r['disaster']),
                  height: 140,
                  borderRadius: BorderRadius.circular(Radii.lg),
                ),
                Gaps.v12,
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        '${r['disaster'] ?? 'Disaster'} in Barangay '
                        '${r['barangay'] ?? '-'}',
                        style: t.titleLarge,
                      ),
                    ),
                    Gaps.h8,
                    PriorityChip(r['priority_level'] as String?),
                  ],
                ),
                Gaps.v12,
                row(Icons.place_outlined, _place(r)),
                if (r['affected_families'] != null)
                  row(
                    Icons.groups_outlined,
                    '${r['affected_families']} families affected',
                  ),
                if ('${r['description'] ?? ''}'.isNotEmpty)
                  row(Icons.notes, '${r['description']}'),
                Gaps.v8,
                Text(
                  'Assistance needed',
                  style: t.titleSmall?.copyWith(color: cs.primary),
                ),
                Gaps.v8,
                NeedChips(NeedChips.split(r['assistance_needed'])),
                Gaps.v16,
                                Progress(
                  delivered: r['total_items_delivered'] as num? ?? 0,
                  needed: r['total_items_needed'] as num? ?? 0,
                  percent: fulfillmentPercent(r),
                ),
                Gaps.v16,
                Text(
                  'Progress per item',
                  style: t.titleSmall?.copyWith(color: cs.primary),
                ),
                Gaps.v8,
                NeedsProgress(reportId: r['id'] as int),
                if (canDonate) ...[
                  Gaps.v16,
                  AppButton(
                    'Donate',
                    icon: Icons.volunteer_activism_outlined,
                    variant: AppButtonVariant.donate,
                    expand: true,
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      _donate(r, names);
                    },
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// "Sitio Ibabao, Banilad, Mandaue City"
String _place(Map r) => [
  if ('${r['sitio'] ?? ''}'.isNotEmpty) 'Sitio ${r['sitio']}',
  if (r['barangay'] != null) '${r['barangay']}',
  'Mandaue City',
].join(', ');

/// One report in the list: picture, priority, title, place, families, a
/// short description, progress, then Donate (open reports) and Details.
class _ReportListCard extends StatelessWidget {
  final Map<String, dynamic> report;
  final VoidCallback onDetails;
  final VoidCallback? onDonate; // null: fulfilled, no Donate button
  const _ReportListCard({
    required this.report,
    required this.onDetails,
    this.onDonate,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final r = report;
    final pct = (fulfillmentPercent(r) ?? 0).clamp(0, 100);
    Widget meta(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          Icon(icon, size: 15, color: cs.onSurfaceVariant),
          Gaps.h4,
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
    return AppCard(
      margin: const EdgeInsets.only(bottom: Space.sm),
      padding: const EdgeInsets.all(Space.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DisasterArt(
                disasterKind(r['disaster']),
                width: 104,
                height: 112,
                borderRadius: BorderRadius.circular(Radii.md),
              ),
              Gaps.h12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Align(
                      alignment: Alignment.centerRight,
                      child: PriorityChip(r['priority_level'] as String?),
                    ),
                    Gaps.v4,
                    Text(
                      '${r['disaster'] ?? 'Disaster'} in Barangay '
                      '${r['barangay'] ?? '-'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: t.titleSmall,
                    ),
                    meta(Icons.place_outlined, _place(r)),
                    if (r['affected_families'] != null)
                      meta(
                        Icons.groups_outlined,
                        '${r['affected_families']} families affected',
                      ),
                    if ('${r['description'] ?? ''}'.isNotEmpty) ...[
                      Gaps.v4,
                      Text(
                        '${r['description']}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: t.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          Gaps.v8,
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(Radii.pill),
                  child: LinearProgressIndicator(
                    value: pct / 100,
                    minHeight: 6,
                    backgroundColor: cs.surfaceContainerHighest,
                  ),
                ),
              ),
              Gaps.h8,
              Text(
                pct >= 100 ? 'Fulfilled' : '${pct.round()}% fulfilled',
                style: t.labelSmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
          Gaps.v8,
          Row(
            children: [
              if (onDonate != null) ...[
                Expanded(
                  child: AppButton(
                    'Donate',
                    icon: Icons.volunteer_activism_outlined,
                    variant: AppButtonVariant.donate,
                    expand: true,
                    onPressed: onDonate,
                  ),
                ),
                Gaps.h8,
              ],
              Expanded(
                child: OutlinedButton(
                  onPressed: onDetails,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 48),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('Details'),
                      Gaps.h8,
                      Icon(Icons.arrow_forward, size: 18),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Empty list: a picture, what to try, and Reset filters.
class _NoReports extends StatelessWidget {
  final String message;
  final VoidCallback? onReset;
  const _NoReports({required this.message, this.onReset});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xl),
      child: Column(
        children: [
          CircleAvatar(
            radius: 40,
            backgroundColor: cs.primaryContainer,
            child: Icon(
              Icons.search_off,
              size: 40,
              color: cs.onPrimaryContainer,
            ),
          ),
          Gaps.v16,
          Text('No reports found', style: t.titleMedium),
          Gaps.v4,
          Text(
            message,
            textAlign: TextAlign.center,
            style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          if (onReset != null) ...[
            Gaps.v16,
            OutlinedButton.icon(
              onPressed: onReset,
              icon: const Icon(Icons.refresh),
              label: const Text('Reset filters'),
            ),
          ],
        ],
      ),
    );
  }
}

/// "More filters" bottom sheet: disaster type and priority. Progress is
/// the quick chips (Needs assistance / Fulfilled), so it is not repeated
/// here. Pops (type, priority); nothing when closed without applying.
class _MoreFiltersSheet extends StatefulWidget {
  final List<String> types;
  final List<String> priorities;
  final String? type, priority;
  const _MoreFiltersSheet({
    required this.types,
    required this.priorities,
    required this.type,
    required this.priority,
  });

  @override
  State<_MoreFiltersSheet> createState() => _MoreFiltersSheetState();
}

class _MoreFiltersSheetState extends State<_MoreFiltersSheet> {
  late String? type = widget.type, priority = widget.priority;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    Widget group(
      String title,
      List<String> options,
      String? value,
      ValueChanged<String?> onPick,
    ) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: t.titleSmall),
        Gaps.v8,
        Wrap(
          spacing: Space.xs,
          runSpacing: Space.xs,
          children: [
            ChoiceChip(
              label: const Text('All'),
              selected: value == null,
              onSelected: (_) => onPick(null),
            ),
            for (final o in options)
              ChoiceChip(
                label: Text(o),
                selected: value == o,
                onSelected: (_) => onPick(value == o ? null : o),
              ),
          ],
        ),
        Gaps.v16,
      ],
    );

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text('More filters', style: t.titleLarge)),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Gaps.v8,
            group(
              'Disaster type',
              widget.types,
              type,
              (v) => setState(() => type = v),
            ),
            group(
              'Priority',
              widget.priorities,
              priority,
              (v) => setState(() => priority = v),
            ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => setState(() => type = priority = null),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                    ),
                    child: const Text('Clear all'),
                  ),
                ),
                Gaps.h12,
                Expanded(
                  child: FilledButton(
                    onPressed: () =>
                        Navigator.of(context).pop((type, priority)),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 48),
                    ),
                    child: const Text('Apply filters'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
