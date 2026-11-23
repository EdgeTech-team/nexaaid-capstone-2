import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';

import '../shared/paginated_list.dart';
import '../shared/widgets.dart';

// ---------------------------------------------------------------------------
// NF-003 (all roles): a report list loaded a page at a time.
//
// Report Validation, Report Status and Validated Reports used to load every
// report and filter / sort them in the app. Now the server does it
// (backend core/m2_disaster_reporting/report_paging.py) and sends 10 at a time; the counts in
// the Filter panel ("Not Started (9)") come from a counts endpoint with the
// same filters.
// ---------------------------------------------------------------------------

typedef ReportRowBuilder = Widget Function(
  BuildContext context,
  Map<String, dynamic> r,
  Names names,
);

class PagedReportList extends StatefulWidget {
  /// '/reports/validated', '/reports/monitoring' or '/reports/'.
  final String path;

  /// Filters and sort, as the server names them (status, priority_level,
  /// fulfillment, sort, mine).
  final Map<String, String> query;

  /// Counts per fulfillment status with the same filters; null = none.
  final String? countsPath;
  final Map<String, String> countsQuery;

  /// Above the rows: title, filter bar (gets the counts), etc.
  final List<Widget> Function(Map<String, int>? counts) header;
  final ReportRowBuilder itemBuilder;
  final Widget empty;

  /// The report a notification is about: shown first, wherever it is in
  /// the list (it may be on a later page).
  final int? focusId;

  /// Bump to load the list again (e.g. after editing a report).
  final int reloadKey;

  const PagedReportList({
    super.key,
    required this.path,
    required this.query,
    required this.header,
    required this.itemBuilder,
    required this.empty,
    this.countsPath,
    this.countsQuery = const {},
    this.focusId,
    this.reloadKey = 0,
  });

  @override
  State<PagedReportList> createState() => _PagedReportListState();
}

class _PagedReportListState extends State<PagedReportList> {
  late final PagedController _list = PagedController(fetch: _fetch());

  /// Tells the Loader (counts, names) to load again for new filters.
  final _countsChanged = ValueNotifier(0);

  Map<String, dynamic>? _focused;

  PageFetch _fetch() {
    final q = widget.query;
    return (offset, limit) => api.get(
      widget.path,
      query: {...q, 'limit': '$limit', 'offset': '$offset'},
    );
  }

  @override
  void initState() {
    super.initState();
    _loadFocus();
  }

  @override
  void didUpdateWidget(PagedReportList old) {
    super.didUpdateWidget(old);
    final filters =
        !mapEquals(old.query, widget.query) || old.path != widget.path;
    if (filters || old.reloadKey != widget.reloadKey) {
      _list.refresh(fetch: _fetch());
    }
    if (!mapEquals(old.countsQuery, widget.countsQuery) ||
        old.reloadKey != widget.reloadKey) {
      // After this frame, so the Loader reads the new filters.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _countsChanged.value++;
      });
    }
    if (old.focusId != widget.focusId) _loadFocus();
  }

  Future<void> _loadFocus() async {
    final id = widget.focusId;
    if (id == null) {
      if (_focused != null) setState(() => _focused = null);
      return;
    }
    final r = await api.get('/reports/$id');
    if (!mounted || widget.focusId != id) return;
    setState(
      () => _focused = r.ok && r.json is Map
          ? Map<String, dynamic>.from(r.json as Map)
          : null,
    );
  }

  @override
  void dispose() {
    _list.dispose();
    _countsChanged.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final countsPath = widget.countsPath;
    return Loader(
      refresh: _countsChanged,
      load: [
        api.lookupsResult,
        if (countsPath != null)
          () => api.get(countsPath, query: widget.countsQuery),
      ],
      builder: (context, data) {
        final names = Names(Map<String, dynamic>.from(data[0] as Map));
        // data may still be the answer for the old filters (no counts
        // asked then) while the new one loads.
        final counts = countsPath != null && data.length > 1 && data[1] is Map
            ? (data[1] as Map).map((k, v) => MapEntry('$k', (v as num).toInt()))
            : null;
        final focused = _focused;
        return PagedListView(
          controller: _list,
          padding: const EdgeInsets.all(20),
          header: [
            ...widget.header(counts),
            const SizedBox(height: 12),
            if (focused != null) widget.itemBuilder(context, focused, names),
          ],
          empty: focused != null ? const SizedBox.shrink() : widget.empty,
          // The focused report is already on top.
          itemBuilder: (context, r) =>
              focused != null && r['report_id'] == focused['report_id']
              ? const SizedBox.shrink()
              : widget.itemBuilder(
                  context,
                  Map<String, dynamic>.from(r),
                  names,
                ),
        );
      },
    );
  }
}
