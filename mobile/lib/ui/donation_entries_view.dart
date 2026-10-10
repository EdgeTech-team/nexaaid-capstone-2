import 'package:flutter/material.dart';

import 'expiry_widgets.dart';
import 'widgets.dart';

/// Appendix H 4.4 View donation records / 4.5 Monitor donation status.
/// Records are shown per donation entry (one QR / batch_reference) with its
/// items, never one row per item. Rows come from GET /donations/records
/// (staff) or the "entries" of GET /donations/mine (donor / organization).
/// The filters and sort only change what is shown.

const entryStatuses = [
  'Pending',
  'Partly Received',
  'Received',
  'Confirmed',
  // Never handed over in time, or withdrawn (nothing is deleted).
  'Expired',
  'Cancelled',
];
const handoverMethods = ['Drop Off', 'Door to Door'];

enum EntrySort {
  newest('Newest first'),
  oldest('Oldest first'),
  mostItems('Most items'),
  fewestItems('Fewest items'),
  dueSoonest('Due soonest');

  final String label;
  const EntrySort(this.label);
}

String entryReportLabel(Map e) {
  final r = e['report'] as Map?;
  return '${e['report_label'] ?? r?['label'] ?? 'Report #${e['report_id']}'}';
}

String entryTitle(Map e) {
  final n = e['total_items'] as int? ?? (e['items'] as List).length;
  return '${e['entry_no'] != null ? 'Donation ${e['entry_no']}' : '${e['batch_reference']}'}'
      ' · $n ${n == 1 ? 'item' : 'items'}';
}

/// Filters by status, report, handover method and search (QR reference,
/// donor or item name), then sorts. Same rules as the backend's
/// services/donation_entries.filter_and_sort.
List<Map> filterEntries(
  List<Map> entries, {
  String search = '',
  String? status,
  int? reportId,
  String? handover,
  EntrySort sort = EntrySort.newest,
}) {
  final q = search.trim().toLowerCase();
  final shown = entries
      .where((e) => status == null || e['status'] == status)
      .where((e) => reportId == null || e['report_id'] == reportId)
      .where((e) => handover == null || e['handover_method'] == handover)
      .where(
        (e) =>
            q.isEmpty ||
            '${e['batch_reference']}'.toLowerCase().contains(q) ||
            '${e['donor'] ?? ''}'.toLowerCase().contains(q) ||
            (e['items'] as List).any(
              (i) => '${i['item_name']}'.toLowerCase().contains(q),
            ),
      )
      .toList();
  // The first item's id follows the order entries were submitted in.
  int first(Map e) =>
      ((e['items'] as List).first['donation_id'] as num).toInt();
  int count(Map e) => (e['total_items'] as num?)?.toInt() ?? 0;
  shown.sort(switch (sort) {
    EntrySort.newest => (a, b) => first(b).compareTo(first(a)),
    EntrySort.oldest => (a, b) => first(a).compareTo(first(b)),
    EntrySort.mostItems =>
      (a, b) => count(b) != count(a)
          ? count(b).compareTo(count(a))
          : first(b).compareTo(first(a)),
    EntrySort.fewestItems =>
      (a, b) => count(a) != count(b)
          ? count(a).compareTo(count(b))
          : first(b).compareTo(first(a)),
    // Closest to expiring first; donations with no deadline go last.
    EntrySort.dueSoonest => (a, b) {
      final da = '${a['expires_at'] ?? ''}', db = '${b['expires_at'] ?? ''}';
      if (da.isEmpty != db.isEmpty) return da.isEmpty ? 1 : -1;
      final c = da.compareTo(db);
      return c != 0 ? c : first(a).compareTo(first(b));
    },
  });
  return shown;
}

class DonationEntriesView extends StatefulWidget {
  final List<Map> entries;

  /// Optional extra content under each entry (e.g. the donor's timeline).
  final Widget Function(Map entry)? footer;
  final void Function(Map entry)? onTap;
  final String emptyTitle;
  final String emptyMessage;

  const DonationEntriesView({
    super.key,
    required this.entries,
    this.footer,
    this.onTap,
    this.emptyTitle = 'No donations yet.',
    this.emptyMessage = 'Donation entries will show here once submitted.',
  });

  @override
  State<DonationEntriesView> createState() => _DonationEntriesViewState();
}

class _DonationEntriesViewState extends State<DonationEntriesView> {
  final searchC = TextEditingController();
  String search = '';
  String? status;
  int? reportId;
  String? handover;
  EntrySort sort = EntrySort.newest;

  @override
  void dispose() {
    searchC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.entries.isEmpty) {
      return EmptyView(
        icon: Icons.volunteer_activism_outlined,
        title: widget.emptyTitle,
        message: widget.emptyMessage,
        compact: true,
      );
    }
    final reports = <int, String>{};
    for (final e in widget.entries) {
      reports.putIfAbsent(e['report_id'] as int, () => entryReportLabel(e));
    }
    int countOf(String s) =>
        widget.entries.where((e) => e['status'] == s).length;
    final shown = filterEntries(
      widget.entries,
      search: search,
      status: status,
      reportId: reportId,
      handover: handover,
      sort: sort,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final s in <String?>[null, ...entryStatuses])
                Padding(
                  padding: const EdgeInsets.only(right: Space.xs),
                  child: ChoiceChip(
                    label: Text(
                      s == null
                          ? 'All (${widget.entries.length})'
                          : '$s (${countOf(s)})',
                    ),
                    selected: status == s,
                    onSelected: (_) => setState(() => status = s),
                  ),
                ),
            ],
          ),
        ),
        Gaps.v12,
        AppTextField(
          controller: searchC,
          label: widget.entries.any((e) => e['donor'] != null)
              ? 'Search QR reference, donor or item'
              : 'Search QR reference or item',
          icon: Icons.search,
          onChanged: (v) => setState(() => search = v),
        ),
        Gaps.v12,
        DropdownButtonFormField<int?>(
          key: const ValueKey('entries-report'),
          initialValue: reportId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Report'),
          items: [
            const DropdownMenuItem(value: null, child: Text('All reports')),
            for (final e in reports.entries)
              DropdownMenuItem(
                value: e.key,
                child: Text(e.value, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) => setState(() => reportId = v),
        ),
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
                onChanged: (v) => setState(() => handover = v),
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
                onChanged: (v) => setState(() => sort = v ?? sort),
              ),
            ),
          ],
        ),
        Gaps.v16,
        if (shown.isEmpty)
          const EmptyView(
            icon: Icons.filter_alt_off_outlined,
            title: 'No donations match.',
            message: 'Try another status, report or search.',
            compact: true,
          ),
        for (final e in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.sm),
            child: DonationEntryCard(
              entry: e,
              footer: widget.footer?.call(e),
              onTap: widget.onTap == null ? null : () => widget.onTap!(e),
            ),
          ),
      ],
    );
  }
}

/// One donation entry: its status, report, handover, and every item with
/// its own status, received quantity and CMO hold reason.
class DonationEntryCard extends StatelessWidget {
  final Map entry;
  final Widget? footer;
  final VoidCallback? onTap;
  const DonationEntryCard({
    super.key,
    required this.entry,
    this.footer,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final muted = t.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    final items = (e['items'] as List).cast<Map>();
    final mixed = items.map((i) => i['status']).toSet().length > 1;
    return AppCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entryTitle(e), style: t.titleMedium),
                    Text('For ${entryReportLabel(e)}', style: muted),
                  ],
                ),
              ),
              Gaps.h8,
              StatusChip('${e['status']}'),
            ],
          ),
          Gaps.v8,
          Wrap(
            spacing: Space.md,
            runSpacing: Space.xxs,
            children: [
              _Meta(Icons.qr_code_2, '${e['batch_reference']}'),
              if (e['donor'] != null)
                _Meta(Icons.person_outline, '${e['donor']}'),
              _Meta(Icons.local_shipping_outlined, '${e['handover_method']}'),
              _Meta(Icons.event_outlined, niceDate(e['created_at'])),
            ],
          ),
          // Deadline to hand it over, or when and why it was closed.
          if (isClosedEntry(e) ||
              e['expires_label'] != null ||
              (e['closed_items'] as num? ?? 0) > 0) ...[
            Gaps.v8,
            ExpiryNote(e, forStaff: e['donor'] != null),
          ],
          if ((e['on_hold_items'] as num? ?? 0) > 0) ...[
            Gaps.v8,
            const StatusChip('On Hold'),
          ],
          const Divider(height: Space.lg),
          for (final i in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.xxs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.inventory_2_outlined,
                    size: 18,
                    color: cs.onSurfaceVariant,
                  ),
                  Gaps.h8,
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${i['quantity']} ${i['unit'] ?? ''} ${i['item_name']}'
                              .replaceAll(RegExp(r'\s+'), ' '),
                          style: t.bodyMedium,
                        ),
                        Text(
                          [
                            if (i['packaging'] != null) '${i['packaging']}',
                            if (i['actual_quantity_received'] != null)
                              '${i['actual_quantity_received']} received',
                          ].join(' · '),
                          style: muted,
                        ),
                        if (i['hold_reason'] != null)
                          Text('On hold: ${i['hold_reason']}', style: muted),
                      ],
                    ),
                  ),
                  if (mixed || i['hold_reason'] != null) ...[
                    Gaps.h8,
                    StatusChip(
                      i['hold_reason'] != null ? 'On Hold' : '${i['status']}',
                    ),
                  ],
                ],
              ),
            ),
          if (footer != null) ...[Gaps.v16, footer!],
        ],
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Meta(this.icon, this.text);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: cs.onSurfaceVariant),
        Gaps.h4,
        Flexible(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
