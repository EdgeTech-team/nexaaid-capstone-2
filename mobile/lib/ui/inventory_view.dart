import 'package:flutter/material.dart';

import '../design/design.dart';

/// 5.1.3 Inventory tab of the CSWS Receive screen (Inventory module).
/// Rows come from GET /donations/inventory. Stock is linked to a report, so
/// rows stay grouped by report; the filter and sort only change what is shown.

enum InventorySort {
  itemAz('Item A–Z'),
  quantityHigh('Quantity: high to low'),
  quantityLow('Quantity: low to high'),
  lastUpdated('Last updated');

  final String label;
  const InventorySort(this.label);
}

String inventoryReportLabel(Map row) =>
    '${row['report_label'] ?? 'Report #${row['report_id']}'}';

/// Filters by item name and report, sorts, then groups by report
/// (report order follows the first row of each report after sorting).
Map<String, List<Map>> filterInventory(
  List<Map> rows, {
  String search = '',
  int? reportId,
  InventorySort sort = InventorySort.itemAz,
}) {
  final q = search.trim().toLowerCase();
  final shown = rows
      .where((r) => reportId == null || r['report_id'] == reportId)
      .where((r) => '${r['item_name']}'.toLowerCase().contains(q))
      .toList();
  int qty(Map r) => (r['quantity'] as num?)?.toInt() ?? 0;
  DateTime when(Map r) =>
      DateTime.tryParse('${r['last_updated']}') ?? DateTime(0);
  String name(Map r) => '${r['item_name']}'.toLowerCase();
  shown.sort(switch (sort) {
    InventorySort.itemAz => (a, b) => name(a).compareTo(name(b)),
    InventorySort.quantityHigh => (a, b) => qty(b).compareTo(qty(a)),
    InventorySort.quantityLow => (a, b) => qty(a).compareTo(qty(b)),
    InventorySort.lastUpdated => (a, b) => when(b).compareTo(when(a)),
  });
  final byReport = <String, List<Map>>{};
  for (final r in shown) {
    byReport.putIfAbsent(inventoryReportLabel(r), () => []).add(r);
  }
  return byReport;
}

class InventoryView extends StatefulWidget {
  final List<Map> rows;
  const InventoryView({super.key, required this.rows});

  @override
  State<InventoryView> createState() => _InventoryViewState();
}

class _InventoryViewState extends State<InventoryView> {
  final searchC = TextEditingController();
  String search = '';
  int? reportId;
  InventorySort sort = InventorySort.itemAz;

  @override
  void dispose() {
    searchC.dispose();
    super.dispose();
  }

  String _updated(Map r) {
    final d = DateTime.tryParse('${r['last_updated']}')?.toLocal();
    if (d == null) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    return 'Updated ${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    if (widget.rows.isEmpty) {
      return const EmptyView(
        icon: Icons.warehouse_outlined,
        title: 'Inventory is empty.',
        compact: true,
      );
    }
    final reports = <int, String>{};
    for (final r in widget.rows) {
      reports.putIfAbsent(r['report_id'] as int, () => inventoryReportLabel(r));
    }
    final groups = filterInventory(
      widget.rows,
      search: search,
      reportId: reportId,
      sort: sort,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppTextField(
          controller: searchC,
          label: 'Search item name',
          icon: Icons.search,
          onChanged: (v) => setState(() => search = v),
        ),
        Gaps.v12,
        DropdownButtonFormField<int?>(
          key: const ValueKey('inventory-report'),
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
        DropdownButtonFormField<InventorySort>(
          key: const ValueKey('inventory-sort'),
          initialValue: sort,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Sort by'),
          items: [
            for (final s in InventorySort.values)
              DropdownMenuItem(value: s, child: Text(s.label)),
          ],
          onChanged: (v) => setState(() => sort = v ?? sort),
        ),
        Gaps.v16,
        if (groups.isEmpty)
          const EmptyView(
            icon: Icons.search_off,
            title: 'No items match.',
            message: 'Try another name or report.',
            compact: true,
          ),
        for (final e in groups.entries)
          AppCard(
            margin: const EdgeInsets.only(bottom: Space.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.key, style: t.titleSmall),
                const Divider(),
                for (final i in e.value)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Space.xxs),
                    child: Row(
                      children: [
                        Icon(
                          Icons.warehouse_outlined,
                          size: 18,
                          color: cs.onSurfaceVariant,
                        ),
                        Gaps.h8,
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${i['item_name']}', style: t.bodyMedium),
                              if (_updated(i).isNotEmpty)
                                Text(
                                  _updated(i),
                                  style: t.bodySmall?.copyWith(
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Text(
                          '${i['quantity']} ${i['unit'] ?? ''}'.trim(),
                          style: t.titleSmall,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
