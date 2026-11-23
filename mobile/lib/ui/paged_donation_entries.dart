import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart' show Roles;
import 'donation_entries_view.dart';
import 'paginated_list.dart';
import 'widgets.dart';

/// NF-003 pilot: Appendix H 4.4 View donation records / 4.5 Monitor
/// donation status for staff (Administrator, CSWS Main Office, CMO,
/// Barangay Receiving Representative), 20 entries at a time.
///
/// Same layout as [DonationEntriesView], but every filter, the sort and
/// the counts come from the server (GET /donations/records and
/// GET /donations/records/counts with the same filters), because the app
/// no longer holds every entry. [donor]: the signed-in donor's own entries
/// (My giving, GET /donations/mine/entries), 10 per page as well.
class PagedDonationEntries extends StatefulWidget {
  /// Widgets above the filters (title, Scan QR, Entries / Per report).
  final List<Widget> header;
  final Widget Function(Map entry)? footer;
  final String emptyTitle;
  final String emptyMessage;

  /// NF-001: only entries whose report is of this disaster type (the
  /// Administrator's records screen); its name goes in the empty message.
  final int? disasterTypeId;
  final String? disasterTypeName;

  /// One report's records (Reminder 4.4): the report is fixed, so its
  /// dropdown is hidden, and a status summary of the whole report is shown
  /// on top.
  final int? reportId;

  /// NF-003: the donor's own list (My giving). Oct 25: the CMO's
  /// acknowledgement is not shown; acknowledged reads as received.
  final bool donor;

  /// Donor lists from the summary cards: 'waiting' or 'on_the_way'.
  final String? donorView;

  /// Tapping an entry (donor: its detail page).
  final void Function(Map entry)? onTap;

  /// Space between two entry cards (9.4: the donor's list needs more).
  final double gap;

  const PagedDonationEntries({
    super.key,
    this.header = const [],
    this.footer,
    this.disasterTypeId,
    this.disasterTypeName,
    this.reportId,
    this.donor = false,
    this.donorView,
    this.onTap,
    this.gap = Space.sm,
    this.emptyTitle = 'No donations to show.',
    this.emptyMessage = 'Donation entries appear here once donors submit them.',
  });

  @override
  State<PagedDonationEntries> createState() => _PagedDonationEntriesState();
}

/// Sort names the backend accepts (services/donation_entries.ENTRY_SORTS).
const _sortParam = {
  EntrySort.newest: 'newest',
  EntrySort.oldest: 'oldest',
  EntrySort.mostItems: 'most_items',
  EntrySort.fewestItems: 'fewest_items',
  EntrySort.dueSoonest: 'due_soonest',
};

/// Wait this long after the last key press before searching.
const searchDebounce = Duration(milliseconds: 350);

class _PagedDonationEntriesState extends State<PagedDonationEntries> {
  final searchC = TextEditingController();
  Timer? _searchTimer;
  String search = '';
  String? status;
  int? reportId;
  String? handover;
  EntrySort sort = EntrySort.newest;

  /// GET /donations/records/counts for the current filters.
  Map? counts;

  int _countsGeneration = 0;

  late final controller = PagedController(fetch: _fetchFor(_filters()));

  /// The list's filters, also sent to the counts endpoint.
  String get _path =>
      widget.donor ? '/donations/mine/entries' : '/donations/records';
  String get _countsPath => widget.donor
      ? '/donations/mine/entries/counts'
      : '/donations/records/counts';

  Map<String, String> _filters() => {
    if (!widget.donor) 'include_closed': 'true',
    'view': ?widget.donorView,
    'sort': _sortParam[sort]!,
    if (widget.disasterTypeId != null)
      'disaster_type_id': '${widget.disasterTypeId}',
    'status': ?status,
    if ((widget.reportId ?? reportId) != null)
      'report_id': '${widget.reportId ?? reportId}',
    'handover_method': ?handover,
    if (search.trim().isNotEmpty) 'q': search.trim(),
  };

  PageFetch _fetchFor(Map<String, String> filters) =>
      (offset, limit) => api.get(
        _path,
        query: {...filters, 'limit': '$limit', 'offset': '$offset'},
      );

  bool get _filtered =>
      status != null ||
      reportId != null ||
      handover != null ||
      search.trim().isNotEmpty;

  /// Reload the list from page 1 and the counts for the current filters.
  Future<void> _reload() {
    final filters = _filters();
    _loadCounts(filters);
    return controller.refresh(fetch: _fetchFor(filters));
  }

  Future<void> _loadCounts(Map<String, String> filters) async {
    final generation = ++_countsGeneration;
    // The donor's counts cover all of their entries (as before).
    final r = await api.get(_countsPath, query: widget.donor ? null : filters);
    // Answers for an older filter are dropped.
    if (!mounted || generation != _countsGeneration) return;
    setState(() => counts = r.ok && r.json is Map ? r.json as Map : null);
  }

  void _set(VoidCallback change) {
    setState(change);
    _reload();
  }

  void _searchChanged(String v) {
    _searchTimer?.cancel();
    _searchTimer = Timer(searchDebounce, () {
      if (mounted && v != search) _set(() => search = v);
    });
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    searchC.dispose();
    controller.dispose();
    super.dispose();
  }

  /// Entries with status [s] (or 'On Hold'), null until the counts arrive.
  int? _count(String s) {
    final c = counts;
    if (c == null) return null;
    return ((c['by_status'] as Map?)?[s] as num?)?.toInt() ?? 0;
  }

  String _chipLabel(String? s) {
    final int? n = s == null ? (counts?['all'] as num?)?.toInt() : _count(s);
    final name = s == null ? 'All' : donationStatusText(s, donor: widget.donor);
    return n == null ? name : '$name ($n)';
  }

  List<Widget> _filterBar(BuildContext context) {
    final reports = ((counts?['reports'] as List?) ?? const []).cast<Map>();
    return [
      // Defense fixes (Nov 23): a report's own records have no "Needs
      // attention" card; the status chips below filter them.
      if (widget.reportId == null) ...[
        EntryAttentionCard(
          counts: {for (final (s, _) in attentionStatuses) s: _count(s) ?? 0},
          selected: status,
          onSelect: (s) => _set(() => status = status == s ? null : s),
        ),
        Gaps.v12,
      ],
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final s in <String?>[null, ...entryStatuses])
              if ((s != 'Partly Received' || (_count(s!) ?? 0) > 0) &&
                  !(widget.donor && s == 'Confirmed'))
                Padding(
                  padding: const EdgeInsets.only(right: Space.xs),
                  child: ChoiceChip(
                    label: Text(_chipLabel(s)),
                    selected: status == s,
                    onSelected: (_) => _set(() => status = s),
                  ),
                ),
          ],
        ),
      ),
      Gaps.v12,
      AppTextField(
        controller: searchC,
        label: api.role == Roles.barangay || widget.donor
            ? 'Search QR reference or item'
            : 'Search QR reference, donor or item',
        icon: Icons.search,
        onChanged: _searchChanged,
      ),
      if (widget.reportId == null && reports.length > 1) ...[
        Gaps.v12,
        DropdownButtonFormField<int?>(
          key: const ValueKey('entries-report'),
          initialValue: reportId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Report'),
          items: [
            const DropdownMenuItem(value: null, child: Text('All reports')),
            for (final r in reports)
              DropdownMenuItem(
                value: r['report_id'] as int,
                child: Text(
                  '${r['report_label'] ?? 'Report #${r['report_id']}'}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (v) => _set(() => reportId = v),
        ),
      ],
      Gaps.v12,
      Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String?>(
              key: const ValueKey('entries-handover'),
              initialValue: handover,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Handover'),
              items: [
                const DropdownMenuItem(value: null, child: Text('All')),
                for (final h in handoverMethods)
                  DropdownMenuItem(value: h, child: Text(h)),
              ],
              onChanged: (v) => _set(() => handover = v),
            ),
          ),
          Gaps.h12,
          Expanded(
            child: DropdownButtonFormField<EntrySort>(
              key: const ValueKey('entries-sort'),
              initialValue: sort,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Sort by'),
              items: [
                for (final s in EntrySort.values)
                  DropdownMenuItem(value: s, child: Text(s.label)),
              ],
              onChanged: (v) {
                if (v != null && v != sort) _set(() => sort = v);
              },
            ),
          ),
        ],
      ),
      Gaps.v16,
    ];
  }

  @override
  Widget build(BuildContext context) {
    return PagedListView(
      controller: controller,
      onRefresh: _reload,
      header: [
        ...widget.header,
        // Defense fixes (Nov 23): no "Status summary" / "Needs attention"
        // on a report's records; the status chips below filter them.
        ..._filterBar(context),
      ],
      empty: _filtered
          ? const EmptyView(
              icon: Icons.filter_alt_off_outlined,
              title: 'No donations match.',
              message: 'Try another status, report or search.',
              compact: true,
            )
          : EmptyView(
              icon: Icons.volunteer_activism_outlined,
              title: widget.disasterTypeName != null
                  ? 'No donations for ${widget.disasterTypeName} yet.'
                  : widget.emptyTitle,
              message: widget.emptyMessage,
              compact: true,
            ),
      itemBuilder: (context, e) => Padding(
        key: ValueKey('entry-${e['batch_reference']}'),
        padding: EdgeInsets.only(bottom: widget.gap),
        child: DonationEntryCard(
          entry: e,
          footer: widget.footer?.call(e),
          onTap: widget.onTap == null ? null : () => widget.onTap!(e),
          donor: widget.donor,
        ),
      ),
    );
  }
}
