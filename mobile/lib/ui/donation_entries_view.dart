import 'package:flutter/material.dart';

import 'expiry_widgets.dart';
import 'widgets.dart';

/// Appendix H 4.4 View donation records / 4.5 Monitor donation status.
/// Records are shown per donation entry (one QR / batch_reference) with its
/// items, never one row per item. Rows come from GET /donations/records
/// (staff) or the "entries" of GET /donations/mine (donor / organization).
/// The filters and sort only change what is shown.

// Oct 13: items that were not brought are closed at receiving ("Not
// brought"), so new entries never become Partly Received. The chip and the
// summary still show it only while older entries have it.
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

/// problema_napud 4.4 / 4.5: the statuses that need someone to act, each
/// with what it means, in their own section above the list. 'On Hold' is
/// not an entry status: it is an entry with an item the CMO put on hold.
const attentionStatuses = <(String, String)>[
  (
    'On Hold',
    "The City Mayor's Office paused the acknowledgement. The reason is on the entry.",
  ),
  (
    'Expired',
    'Not handed over by its deadline. CSWS can reopen it when the goods come.',
  ),
];

/// [status] matches the entry's status, or 'On Hold' = has an item on hold.
bool entryHasStatus(Map e, String status) => status == 'On Hold'
    ? (e['on_hold_items'] as num? ?? 0) > 0
    : e['status'] == status;

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
      .where((e) => status == null || entryHasStatus(e, status))
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

  /// The "Report" dropdown. Off on a single report's records page.
  final bool reportFilter;

  /// Space between two entry cards (9.4: the donor's list needs more).
  final double gap;

  const DonationEntriesView({
    super.key,
    required this.entries,
    this.footer,
    this.onTap,
    this.emptyTitle = 'No donations yet.',
    this.emptyMessage = 'Donation entries will show here once submitted.',
    this.reportFilter = true,
    this.gap = Space.sm,
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
        widget.entries.where((e) => entryHasStatus(e, s)).length;
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
        _AttentionCard(
          counts: {for (final (s, _) in attentionStatuses) s: countOf(s)},
          selected: status,
          onSelect: (s) => setState(() => status = status == s ? null : s),
        ),
        Gaps.v12,
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final s in <String?>[null, ...entryStatuses])
                if (s != 'Partly Received' || countOf(s!) > 0)
                  Padding(
                    padding: const EdgeInsets.only(right: Space.xs),
                    child: ChoiceChip(
                      label: Text(
                        s == null
                            ? 'All (${widget.entries.length})'
                            : '${donationStatusText(s)} (${countOf(s)})',
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
        if (widget.reportFilter && reports.length > 1) ...[
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
            padding: EdgeInsets.only(bottom: widget.gap),
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

/// "Needs attention": Partly Received, On Hold and Expired with their
/// counts and meaning. Tap one to show only those entries; tap it again
/// to show all.
class _AttentionCard extends StatelessWidget {
  final Map<String, int> counts;
  final String? selected;
  final ValueChanged<String> onSelect;
  const _AttentionCard({
    required this.counts,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return AppCard(
      key: const ValueKey('needs-attention'),
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.md,
              Space.xs,
              Space.md,
              Space.xxs,
            ),
            child: Text('Needs attention', style: t.titleMedium),
          ),
          for (final (status, meaning) in attentionStatuses)
            InkWell(
              key: ValueKey('attention-$status'),
              onTap: () => onSelect(status),
              child: Container(
                color: selected == status
                    ? cs.primaryContainer.withValues(alpha: 0.6)
                    : null,
                padding: const EdgeInsets.symmetric(
                  horizontal: Space.md,
                  vertical: Space.xs,
                ),
                child: Row(
                  children: [
                    Icon(switch (status) {
                      'Partly Received' => Icons.incomplete_circle,
                      'On Hold' => Icons.pause_circle_outline,
                      _ => Icons.timer_off_outlined,
                    }, color: StatusColors.base(status)),
                    Gaps.h12,
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(donationStatusText(status), style: t.titleSmall),
                          Text(
                            meaning,
                            style: t.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Gaps.h8,
                    Text(
                      '${counts[status] ?? 0}',
                      style: t.titleLarge?.copyWith(
                        color: (counts[status] ?? 0) > 0
                            ? StatusColors.base(status)
                            : cs.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Status summary on top of a report's donation records (Reminder 4.4):
/// how many entries there are and how many are at each status.
class EntryStatusSummary extends StatelessWidget {
  final List<Map> entries;
  const EntryStatusSummary(this.entries, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final counts = {
      for (final s in entryStatuses)
        s: entries.where((e) => e['status'] == s).length,
    }..removeWhere((_, n) => n == 0);
    final items = entries.fold<int>(
      0,
      (n, e) => n + ((e['total_items'] as num?)?.toInt() ?? 0),
    );
    return AppCard(
      key: const ValueKey('entry-status-summary'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Status summary', style: t.titleMedium),
          Gaps.v4,
          Text(
            '${entries.length} ${entries.length == 1 ? 'entry' : 'entries'}'
            ' · $items ${items == 1 ? 'item' : 'items'}',
            style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          if (counts.isNotEmpty) ...[
            Gaps.v12,
            // One bar split by status, so the mix shows at a glance.
            ClipRRect(
              borderRadius: BorderRadius.circular(Radii.sm),
              child: Row(
                children: [
                  for (final c in counts.entries)
                    Expanded(
                      flex: c.value,
                      child: Container(
                        height: 8,
                        color: StatusColors.base(c.key),
                      ),
                    ),
                ],
              ),
            ),
            Gaps.v12,
            Wrap(
              spacing: Space.md,
              runSpacing: Space.xs,
              children: [
                for (final c in counts.entries)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.circle,
                        size: 10,
                        color: StatusColors.base(c.key),
                      ),
                      Gaps.h4,
                      Text(
                        '${c.value} ${donationStatusText(c.key)}',
                        style: t.bodyMedium,
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ],
      ),
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
              // Oct 13: once its goods are on a delivery, the chip follows
              // the timeline (In Transit / Delivered / Barangay confirmed).
              switch (e['lifecycle_status']) {
                'In Transit' => const StatusChip(
                  'In Transit',
                  label: 'In transit',
                ),
                'Delivered' => const StatusChip('Delivered'),
                'Acknowledged' => const StatusChip(
                  'Confirmed',
                  label: 'Barangay confirmed',
                ),
                _ => DonationStatusChip('${e['status']}'),
              },
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
                    if (isNotBrought(i))
                      const StatusChip('Cancelled', label: 'Not brought')
                    else
                      DonationStatusChip(
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
