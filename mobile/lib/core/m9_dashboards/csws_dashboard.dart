import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../shared/api.dart';
import '../notifications/realtime.dart';
import '../m5_inventory/batch_sheet.dart' show openDonationByQr;
import '../m5_inventory/csws_screens.dart' show ActivityList;
import '../shared/home_nav.dart';
import '../m7_logistics_support/ops_screens.dart' show showDeliveryHistory;
import '../m8_delivery_tracking/scheduled_deliveries.dart';
import '../shared/widgets.dart';

// ---------------------------------------------------------------------------
// CSWS Main Office dashboard (Nov 23, 2026).
//
//   four cards   Waiting to be received (opens its page), Expired or
//                cancelled (a number only), Entries received (Receive tab),
//                Deliveries made (Deliveries tab)
//   Scheduled deliveries, as before (overdue first)
//   Inventory    6 items, then the Inventory page: Summary | Per report,
//                both what CSWS received and still holds
//   Recent activity, as before
//
// Backend: api/v1/dashboard_routes.py (overview) and
// api/v1/csws_overview_routes.py (the pages).
// ---------------------------------------------------------------------------

abstract final class CswsColors {
  static const harbor = AppColors.harbor;
  static const deep = AppColors.harborDeep;
  static const mist = AppColors.harborMist;
  static const iconMist = Color(0xFFE3F1EF);
  static const blueBg = Color(0xFFE3EEFA);
  static const blue = Color(0xFF1F5FA8);
  static const greenBg = Color(0xFFE6F4EA);
  static const green = Color(0xFF2E7D32);
  static const indigoBg = Color(0xFFEEF0F7);
  static const indigo = Color(0xFF4B5A8C);
  static const greyBg = Color(0xFFEEF1F0);
  static const grey = Color(0xFF4A5553);
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------
String _n(Object? v) {
  final i = (v is num) ? v.round() : int.tryParse('${v ?? ''}') ?? 0;
  final s = i.abs().toString();
  final b = StringBuffer();
  for (var k = 0; k < s.length; k++) {
    if (k > 0 && (s.length - k) % 3 == 0) b.write(',');
    b.write(s[k]);
  }
  return i < 0 ? '-$b' : '$b';
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "Nov 20"
String shortDate(Object? iso) {
  final d = DateTime.tryParse('${iso ?? ''}')?.toLocal();
  return d == null ? '' : '${_months[d.month - 1]} ${d.day}';
}

/// "Today", "1 day", "3 days"
String daysText(Object? days) {
  final n = (days is num) ? days.toInt() : int.tryParse('$days') ?? 0;
  if (n <= 0) return 'Today';
  return n == 1 ? '1 day' : '$n days';
}

String _more(Object? n) {
  final k = (n is num) ? n.toInt() : 0;
  return k > 0 ? ' +$k more' : '';
}

// ---------------------------------------------------------------------------
// Item icons (Dave's item icon set): one icon per catalog item, in its
// category color on a soft tint. Matched by item name; any other item
// shows its category icon, and anything else a box.
// ---------------------------------------------------------------------------
String itemSvgAsset(Object? itemName, [Object? category]) {
  final n = '${itemName ?? ''}'.toLowerCase();
  bool has(List<String> words) => words.any(n.contains);
  String file;
  if (has(['rice', 'grain'])) {
    file = 'rice';
  } else if (has(['canned', 'sardine', 'tuna', 'corned'])) {
    file = 'canned';
  } else if (has(['noodle', 'pasta'])) {
    file = 'noodles';
  } else if (has(['water', 'drink'])) {
    file = 'water';
  } else if (has(['medic', 'first aid', 'vitamin'])) {
    file = 'med';
  } else if (has(['hygiene', 'soap'])) {
    file = 'hyg';
  } else if (has(['diaper', 'baby'])) {
    file = 'diaper';
  } else if (has(['blanket', 'mat'])) {
    file = 'blanket';
  } else if (has(['lower', 'pants', 'short'])) {
    file = 'pants';
  } else if (has(['cloth', 'shirt'])) {
    file = 'cloth';
  } else if (has(['kitchen', 'utensil', 'cook'])) {
    file = 'kitchen';
  } else if (has(['tent', 'tarp'])) {
    file = 'tent';
  } else {
    file = switch ('${category ?? ''}') {
      'Food' => 'rice',
      'Water' => 'water',
      'Medical' => 'med',
      'Hygiene' => 'hyg',
      'Shelter' => 'blanket',
      'Clothing' => 'cloth',
      'Kitchen' => 'kitchen',
      _ => 'other', // "Any", donor-typed (Other), anything else: a box
    };
  }
  return 'assets/item_icons/$file.svg';
}

/// The category color of an item icon and its soft tint (Dave's set).
(Color, Color) itemIconColors(String asset) {
  final file = asset.split('/').last.replaceAll('.svg', '');
  return switch (file) {
    'rice' || 'canned' || 'noodles' => (
      const Color(0xFFC2410C),
      const Color(0xFFFFF1EA),
    ), // Food
    'water' => (const Color(0xFF1D4ED8), const Color(0xFFEFF6FF)),
    'hyg' || 'diaper' => (const Color(0xFF6D28D9), const Color(0xFFF3EEFF)),
    'blanket' || 'tent' => (const Color(0xFF15803D), const Color(0xFFEAFBF1)),
    'med' => (const Color(0xFFBE185D), const Color(0xFFFDEEF4)),
    'cloth' || 'pants' => (const Color(0xFFC0267E), const Color(0xFFFCEFF7)),
    'kitchen' => (const Color(0xFFB45309), const Color(0xFFFFF8EB)),
    'report' => (CswsColors.harbor, CswsColors.iconMist),
    _ => (const Color(0xFF475569), const Color(0xFFF1F5F9)), // Any other item
  };
}

/// An item icon in its category color, without the tile.
Widget itemSvg(String asset, double size) => SvgPicture.asset(
  asset,
  width: size,
  height: size,
  colorFilter: ColorFilter.mode(itemIconColors(asset).$1, BlendMode.srcIn),
);

class ItemIcon extends StatelessWidget {
  final Object? itemName;
  final Object? category;
  final double size;
  final String? asset;
  const ItemIcon(
    this.itemName, {
    super.key,
    this.category,
    this.size = 44,
    this.asset,
  });

  @override
  Widget build(BuildContext context) {
    final file = asset ?? itemSvgAsset(itemName, category);
    final (fg, bg) = itemIconColors(file);
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(size * 0.25),
          border: Border.all(color: fg.withValues(alpha: 0.18)),
        ),
        child: itemSvg(file, size * 0.6),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Status tags (no warning colors)
// ---------------------------------------------------------------------------
enum TagKind { serious, transport, neutral, done }

class CswsTag extends StatelessWidget {
  final String label;
  final TagKind kind;
  final IconData? icon;
  const CswsTag(this.label, {super.key, this.kind = TagKind.neutral, this.icon});

  const CswsTag.overdue(this.label, {super.key})
    : kind = TagKind.serious,
      icon = Icons.schedule;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (kind) {
      TagKind.serious => (CswsColors.mist, CswsColors.deep),
      TagKind.transport => (CswsColors.blueBg, CswsColors.blue),
      TagKind.done => (CswsColors.greenBg, CswsColors.green),
      TagKind.neutral => (CswsColors.greyBg, CswsColors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 14, color: fg), Gaps.h4],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: fg,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Layout pieces
// ---------------------------------------------------------------------------

/// The app's own card (the copy-develop look before PR #124), tappable.
class CswsCard extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  const CswsCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(Space.md),
  });

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(padding: padding, child: child),
    ),
  );
}

Future<void> _push(BuildContext context, Widget page) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));

// ---------------------------------------------------------------------------
// The overview
// ---------------------------------------------------------------------------
class CswsMainDashboard extends StatelessWidget {
  const CswsMainDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    return Loader(
      // Live: a delivery or DRRMO request changed (Realtime).
      refresh: Realtime.instance.logistics,
      load: [
        // The server works this out from many tables; on a busy database
        // it can take longer than the usual 20 s.
        () => api.get(
          '/dashboard/csws-main',
          timeout: const Duration(seconds: 45),
        ),
        // Testing #19: deliveries that have not arrived yet.
        () => api.get('/deliveries/', query: scheduledDeliveriesQuery),
      ],
      builder: (context, data) =>
          _Overview(data[0] as Map, (data[1] as List).cast<Map>()),
    );
  }
}

class _Overview extends StatelessWidget {
  final Map m;
  final List<Map> scheduled;
  const _Overview(this.m, this.scheduled);

  @override
  Widget build(BuildContext context) {
    final inv = (m['inventory'] as Map?) ?? const {};
    final invRows = ((inv['rows'] as List?) ?? const []).cast<Map>().take(6).toList();
    final logs = ((m['recent_activity'] as List?) ?? const []).cast<Map>();
    final expired = (m['expired_donations'] as num?) ?? 0;
    final cancelled = (m['cancelled_donations'] as num?) ?? 0;
    final due = (m['due_today'] as num?) ?? 0;
    final withStock = (inv['reports_with_stock'] as num?) ?? 0;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    // The four cards are the app's own stat tiles (copy-develop sizes).
    final cards = StatGrid([
      StatTile(
        'Waiting to be received',
        _n(m['waiting']),
        Icons.move_to_inbox_outlined,
        note: due == 0 ? 'None due today' : '${_n(due)} due today or late',
        onTap: () => _push(context, const WaitingPage()),
      ),
      // A number only (not clickable).
      StatTile(
        'Expired or cancelled',
        _n(expired + cancelled),
        Icons.timer_off_outlined,
        color: CswsColors.grey,
        note: '${_n(expired)} expired · ${_n(cancelled)} cancelled',
      ),
      StatTile(
        'Entries received',
        _n(m['entries_received']),
        Icons.inventory_2_outlined,
        onTap: () => HomeNav.go(context, const HomeTarget('Receive')),
      ),
      StatTile(
        'Deliveries made',
        _n(m['deliveries_made']),
        Icons.local_shipping_outlined,
        onTap: () => HomeNav.go(context, const HomeTarget('Deliveries')),
      ),
    ]);

    // The copy-develop look before PR #124 (page header, section titles,
    // plain cards with list rows); the content is the Nov 23 dashboard.
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const PageHeader(
          'CSWS Main Office Dashboard',
          subtitle: 'CSWS Main Office',
        ),
        cards,
        ScheduledDeliveriesCard(
          deliveries: scheduled,
          onOpen: (d) => showDeliveryHistory(context, d['delivery_id'] as int),
          onSeeAll: () => HomeNav.go(context, const HomeTarget('Deliveries')),
        ),
        SectionTitle(
          'Inventory summary',
          trailing: Text(
            '${invRows.length} of ${_n(inv['total'])} items',
            style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
        if (invRows.isEmpty)
          const EmptyState('Inventory is empty.')
        else
          Card(
            child: Column(
              children: [for (final i in invRows) _StockRow(i)],
            ),
          ),
        Gaps.v8,
        OutlinedButton.icon(
          onPressed: () => _push(context, const InventoryPage()),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          icon: const Icon(Icons.inventory_2_outlined),
          label: Text('View all inventory (${_n(inv['total'])})'),
        ),
        Gaps.v8,
        Card(
          child: ListTile(
            onTap: () => _push(context, const InventoryPage(perReport: true)),
            leading: const Icon(Icons.assignment_outlined),
            title: const Text('Per report'),
            subtitle: Text(
              'Stock held for ${_n(withStock)} '
              '${withStock == 1 ? 'report' : 'reports'}',
            ),
            trailing: const Icon(Icons.chevron_right),
          ),
        ),
        const SectionTitle('Recent activity'),
        ActivityList(logs),
      ],
    );
  }
}

/// One item in the overview's inventory card: icon, name, quantity.
class _StockRow extends StatelessWidget {
  final Map i;
  const _StockRow(this.i);

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    leading: ItemIcon(i['item_name'], category: i['category'], size: 36),
    title: Text('${i['item_name']}', maxLines: 1, overflow: TextOverflow.ellipsis),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (i['low'] == true) ...[
          const StatusChip('Pending', label: 'Low'),
          Gaps.h8,
        ],
        Text(
          '${_n(i['quantity'])} ${i['unit'] ?? ''}'.trim(),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// The page template
// ---------------------------------------------------------------------------
class ListChip {
  /// Query value ('' = All, no filter sent).
  final String value;
  final String label;

  /// Key in the /counts answer.
  final String countKey;
  const ListChip(this.value, this.label, this.countKey);
}

class ListSort {
  final String value;
  final String label;
  const ListSort(this.value, this.label);
}

typedef RowBuilder = Widget Function(BuildContext context, Map row, VoidCallback reload);

/// Teal band with a back link, search, the Filter button and Sort menu of
/// every report list (Nov 24: a panel with the chips and their counts, plus
/// Barangay and Disaster type when [placeFilters]; a removable chip for each
/// filter that is on), "Showing 1–10 of N", 10 rows at a time loaded as the list scrolls (a
/// "Load 10 more" button on the web), "That's all N", pull to refresh and
/// an empty state. A chip, search or sort change starts again at the first
/// 10; answers for an older filter are dropped.
class CswsListPage extends StatefulWidget {
  final String title;
  final String description;
  final String path;
  final String? countsPath;
  final String chipParam;
  final List<ListChip> chips;
  final String initialChip;
  final List<ListSort> sorts;
  final String searchHint;

  /// The chips' section title in the Filter panel ("Category").
  final String chipTitle;

  /// Barangay and Disaster type in the Filter panel (sent as barangay_id
  /// and disaster_type_id), as in every report list.
  final bool placeFilters;
  final RowBuilder itemBuilder;
  final String emptyTitle;
  final String emptyMessage;

  /// Widgets between the band and the chips (the Inventory tabs).
  final List<Widget> top;

  const CswsListPage({
    super.key,
    required this.title,
    required this.description,
    required this.path,
    required this.itemBuilder,
    required this.emptyTitle,
    required this.emptyMessage,
    this.countsPath,
    this.chipParam = '',
    this.chips = const [],
    this.initialChip = '',
    this.sorts = const [],
    this.searchHint = 'Search',
    this.chipTitle = 'Show',
    this.placeFilters = false,
    this.top = const [],
  });

  @override
  State<CswsListPage> createState() => _CswsListPageState();
}

class _CswsListPageState extends State<CswsListPage> {
  static const pageSize = 10;
  final _scroll = ScrollController();
  final _search = TextEditingController();
  Timer? _debounce;

  late String chip = widget.initialChip;
  late String sort = widget.sorts.isEmpty ? '' : widget.sorts.first.value;
  String q = '';
  int? barangayId;
  String? barangayName;
  int? disasterTypeId;
  String? disasterTypeName;

  final List<Map> items = [];
  int? total;
  Map counts = const {};
  bool loading = false;
  bool loadedOnce = false;
  ApiResult? error;
  int _generation = 0;

  bool get hasMore => total == null ? !loadedOnce : items.length < total!;
  /// Filters on, for the badge on the Filter button.
  int get activeFilters =>
      (chip != widget.initialChip ? 1 : 0) +
      (barangayId != null ? 1 : 0) +
      (disasterTypeId != null ? 1 : 0);
  bool get filtered => q.isNotEmpty || activeFilters > 0;

  Map<String, String> get _place => {
    if (barangayId != null) 'barangay_id': '$barangayId',
    if (disasterTypeId != null) 'disaster_type_id': '$disasterTypeId',
  };

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_nearEnd);
    api.addListener(_quiet);
    Realtime.instance.logistics.addListener(_quiet);
    _restart();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    _search.dispose();
    api.removeListener(_quiet);
    Realtime.instance.logistics.removeListener(_quiet);
    super.dispose();
  }

  Map<String, String> _query(int offset, int limit) => {
    'limit': '$limit',
    'offset': '$offset',
    if (chip.isNotEmpty && widget.chipParam.isNotEmpty) widget.chipParam: chip,
    if (sort.isNotEmpty) 'sort': sort,
    if (q.isNotEmpty) 'q': q,
    ..._place,
  };

  void _nearEnd() {
    if (kIsWeb) return; // the web build uses the "Load 10 more" button
    final p = _scroll.position;
    if (p.pixels > p.maxScrollExtent - 400) _more();
  }

  Future<void> _restart() async {
    final gen = ++_generation;
    setState(() {
      items.clear();
      total = null;
      loadedOnce = false;
      error = null;
    });
    _loadCounts(gen);
    await _fetch(gen, 0, pageSize, replace: true);
  }

  Future<void> _more() async {
    if (loading || !hasMore || error != null) return;
    await _fetch(_generation, items.length, pageSize);
  }

  /// After an action or a live change: load what is on screen again,
  /// keeping the place in the list.
  Future<void> _quiet() async {
    if (!mounted || loading) return;
    final gen = _generation;
    _loadCounts(gen);
    final n = items.length < pageSize ? pageSize : items.length;
    await _fetch(gen, 0, n > 100 ? 100 : n, replace: true, quiet: true);
  }

  Future<void> _loadCounts(int gen) async {
    final path = widget.countsPath;
    if (path == null) return;
    final r = await api.get(path, query: {if (q.isNotEmpty) 'q': q, ..._place});
    if (!mounted || gen != _generation || !r.ok || r.json is! Map) return;
    setState(() => counts = r.json as Map);
  }

  Future<void> _fetch(
    int gen,
    int offset,
    int limit, {
    bool replace = false,
    bool quiet = false,
  }) async {
    if (!quiet) setState(() => loading = true);
    final r = await api.get(widget.path, query: _query(offset, limit));
    if (!mounted || gen != _generation) return; // an older filter: dropped
    setState(() {
      loading = false;
      if (!r.ok || r.json is! List) {
        if (!quiet) error = r;
        return;
      }
      if (replace) items.clear();
      items.addAll((r.json as List).cast<Map>());
      total = r.total ?? items.length;
      loadedOnce = true;
      error = null;
    });
    // A short first page on a tall screen: fill it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          !kIsWeb &&
          _scroll.hasClients &&
          _scroll.position.maxScrollExtent <= 0) {
        _more();
      }
    });
  }

  /// The Filter panel's Apply / Clear, or a removed chip.
  void _setFilters({
    required String chip,
    int? barangayId,
    String? barangayName,
    int? disasterTypeId,
    String? disasterTypeName,
  }) {
    this.chip = chip;
    this.barangayId = barangayId;
    this.barangayName = barangayId == null ? null : barangayName;
    this.disasterTypeId = disasterTypeId;
    this.disasterTypeName = disasterTypeId == null ? null : disasterTypeName;
    _restart();
  }

  void _setSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (v.trim() == q) return;
      q = v.trim();
      _restart();
    });
  }

  void _clearFilters() {
    _search.clear();
    q = '';
    _setFilters(chip: widget.initialChip);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final sortLabel = widget.sorts
        .firstWhere((s) => s.value == sort, orElse: () => const ListSort('', 'Sort'))
        .label;
    final hasFilter = widget.chips.isNotEmpty || widget.placeFilters;

    // A removable chip for each filter that is on (as in report lists).
    Widget onChip(String label, VoidCallback remove) => InputChip(
      avatar: const Icon(Icons.circle, size: 10, color: CswsColors.harbor),
      label: Text(label),
      visualDensity: VisualDensity.compact,
      onDeleted: remove,
      deleteButtonTooltipMessage: 'Remove $label',
    );
    final chipLabel = widget.chips
        .where((c) => c.value == chip)
        .map((c) => c.label)
        .firstOrNull;
    final onChips = [
      if (chip != widget.initialChip && chipLabel != null)
        onChip(
          chipLabel,
          () => _setFilters(
            chip: widget.initialChip,
            barangayId: barangayId,
            barangayName: barangayName,
            disasterTypeId: disasterTypeId,
            disasterTypeName: disasterTypeName,
          ),
        ),
      if (barangayId != null)
        onChip(
          barangayName ?? 'Barangay',
          () => _setFilters(
            chip: chip,
            disasterTypeId: disasterTypeId,
            disasterTypeName: disasterTypeName,
          ),
        ),
      if (disasterTypeId != null)
        onChip(
          disasterTypeName ?? 'Disaster type',
          () => _setFilters(
            chip: chip,
            barangayId: barangayId,
            barangayName: barangayName,
          ),
        ),
    ];

    Widget footer() {
      if (error != null && items.isEmpty) {
        return ErrorView.forStatus(error!.status, error!.errorText, onRetry: _restart);
      }
      if (!loadedOnce) {
        return const Padding(
          padding: EdgeInsets.all(Space.lg),
          child: Center(child: CircularProgressIndicator()),
        );
      }
      if (items.isEmpty) {
        return EmptyView(
          icon: Icons.inbox_outlined,
          title: widget.emptyTitle,
          message: widget.emptyMessage,
          action: filtered
              ? OutlinedButton(onPressed: _clearFilters, child: const Text('Clear filters'))
              : null,
        );
      }
      if (error != null) {
        return Row(
          children: [
            Expanded(child: Text("Couldn't load more.", style: t.bodyMedium)),
            TextButton.icon(
              onPressed: _more,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        );
      }
      if (loading) {
        return const Padding(
          padding: EdgeInsets.all(Space.md),
          child: Center(child: CircularProgressIndicator()),
        );
      }
      if (hasMore) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.sm),
          child: OutlinedButton(
            onPressed: _more,
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: const Text('Load 10 more'),
          ),
        );
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.md),
        child: Text(
          "That's all ${_n(total)}",
          textAlign: TextAlign.center,
          style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
        ),
      );
    }

    return Scaffold(
      // The copy-develop look before PR #124: a plain app bar with the
      // page title and the back arrow.
      appBar: AppBar(title: Text(widget.title)),
      body: RefreshIndicator(
        onRefresh: _restart,
        child: CustomScrollView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(Space.md, Space.md, Space.md, 0),
              sliver: SliverList.list(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.sm),
                    child: Text(
                      widget.description,
                      style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ),
                  ...widget.top,
                  TextField(
                    controller: _search,
                    onChanged: _setSearch,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: widget.searchHint,
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear search',
                              icon: const Icon(Icons.close),
                              onPressed: () {
                                _search.clear();
                                _setSearch('');
                              },
                            ),
                    ),
                  ),
                  Gaps.v12,
                  Wrap(
                    spacing: Space.xs,
                    runSpacing: Space.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (hasFilter)
                        _ListFilterButton(
                          active: activeFilters,
                          panel: (close) => _ListFilterPanel(
                            chipTitle: widget.chipTitle,
                            chips: widget.chips,
                            counts: counts,
                            placeFilters: widget.placeFilters,
                            chip: chip,
                            initialChip: widget.initialChip,
                            barangayId: barangayId,
                            barangayName: barangayName,
                            disasterTypeId: disasterTypeId,
                            disasterTypeName: disasterTypeName,
                            onApply: _setFilters,
                            close: close,
                          ),
                        ),
                      if (widget.sorts.length > 1)
                        MenuAnchor(
                          alignmentOffset: const Offset(0, Space.xxs),
                          menuChildren: [
                            for (final o in widget.sorts)
                              MenuItemButton(
                                leadingIcon: Icon(
                                  o.value == sort ? Icons.check : null,
                                  size: 18,
                                ),
                                onPressed: () {
                                  if (o.value == sort) return;
                                  sort = o.value;
                                  _restart();
                                },
                                child: Text(o.label),
                              ),
                          ],
                          builder: (context, menu, _) => OutlinedButton.icon(
                            onPressed: () =>
                                menu.isOpen ? menu.close() : menu.open(),
                            icon: const Icon(Icons.sort),
                            label: Text('Sort: $sortLabel'),
                          ),
                        ),
                    ],
                  ),
                  if (onChips.isNotEmpty) ...[
                    Gaps.v8,
                    Wrap(
                      spacing: Space.xs,
                      runSpacing: Space.xs,
                      children: onChips,
                    ),
                  ],
                  if (items.isNotEmpty) ...[
                    Gaps.v12,
                    Text(
                      'Showing 1–${items.length} of ${_n(total ?? items.length)}',
                      style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                  Gaps.v12,
                ],
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(Space.md, 0, Space.md, Space.lg),
              sliver: SliverList.builder(
                itemCount: items.length + 1,
                itemBuilder: (context, i) {
                  if (i == items.length) return footer();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: Space.sm),
                    child: widget.itemBuilder(context, items[i], _quiet),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The Filter button with the number of filters on, opening its panel
/// under it (the same button as in every report list).
class _ListFilterButton extends StatefulWidget {
  final int active;
  final Widget Function(VoidCallback close) panel;
  const _ListFilterButton({required this.active, required this.panel});

  @override
  State<_ListFilterButton> createState() => _ListFilterButtonState();
}

class _ListFilterButtonState extends State<_ListFilterButton> {
  final _menu = MenuController();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return MenuAnchor(
      controller: _menu,
      alignmentOffset: const Offset(0, Space.xxs),
      menuChildren: [widget.panel(_menu.close)],
      builder: (context, menu, _) => Badge(
        isLabelVisible: widget.active > 0,
        label: Text('${widget.active}'),
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

typedef _ApplyFilters =
    void Function({
      required String chip,
      int? barangayId,
      String? barangayName,
      int? disasterTypeId,
      String? disasterTypeName,
    });

/// The panel under the Filter button: the chips with their counts, then
/// Barangay and Disaster type. Choices change a draft; Apply uses it,
/// Clear goes back to all (as in every report list).
class _ListFilterPanel extends StatefulWidget {
  final String chipTitle;
  final List<ListChip> chips;
  final Map counts;
  final bool placeFilters;
  final String chip;
  final String initialChip;
  final int? barangayId;
  final String? barangayName;
  final int? disasterTypeId;
  final String? disasterTypeName;
  final _ApplyFilters onApply;
  final VoidCallback close;

  const _ListFilterPanel({
    required this.chipTitle,
    required this.chips,
    required this.counts,
    required this.placeFilters,
    required this.chip,
    required this.initialChip,
    required this.barangayId,
    required this.barangayName,
    required this.disasterTypeId,
    required this.disasterTypeName,
    required this.onApply,
    required this.close,
  });

  @override
  State<_ListFilterPanel> createState() => _ListFilterPanelState();
}

class _ListFilterPanelState extends State<_ListFilterPanel> {
  late String chip = widget.chip;
  late int? barangayId = widget.barangayId;
  late String? barangayName = widget.barangayName;
  late int? disasterTypeId = widget.disasterTypeId;
  late String? disasterTypeName = widget.disasterTypeName;

  /// Barangays and disaster types for the two dropdowns (GET /lookups).
  late final Future<Map<String, dynamic>> _lookups = api.lookups();

  void _apply({bool clear = false}) {
    if (clear) {
      widget.onApply(chip: widget.initialChip);
    } else {
      widget.onApply(
        chip: chip,
        barangayId: barangayId,
        barangayName: barangayName,
        disasterTypeId: disasterTypeId,
        disasterTypeName: disasterTypeName,
      );
    }
    widget.close();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
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
            if (widget.chips.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.chipTitle, style: t.titleSmall),
                    Gaps.v8,
                    Wrap(
                      spacing: Space.xs,
                      runSpacing: Space.xs,
                      children: [
                        for (final c in widget.chips)
                          ChoiceChip(
                            label: Text(
                              widget.counts.containsKey(c.countKey)
                                  ? '${c.label} (${_n(widget.counts[c.countKey])})'
                                  : c.label,
                            ),
                            selected: chip == c.value,
                            onSelected: (_) => setState(() => chip = c.value),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            if (widget.placeFilters)
              FutureBuilder<Map<String, dynamic>>(
                future: _lookups,
                builder: (context, snap) {
                  List<Map> list(String key) =>
                      ((snap.data?[key] as List?) ?? const []).cast<Map>();
                  Widget pick(
                    String label,
                    List<Map> options,
                    int? value,
                    void Function(int? id, String? name) onPick,
                  ) => Padding(
                    padding: const EdgeInsets.only(bottom: Space.md),
                    child: DropdownButtonFormField<int?>(
                      key: ValueKey('filter-$label-${options.length}'),
                      isExpanded: true,
                      initialValue: options.any((o) => o['id'] == value)
                          ? value
                          : null,
                      decoration: InputDecoration(labelText: label),
                      items: [
                        const DropdownMenuItem<int?>(
                          value: null,
                          child: Text('All'),
                        ),
                        for (final o in options)
                          DropdownMenuItem<int?>(
                            value: (o['id'] as num).toInt(),
                            child: Text(
                              '${o['name']}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (id) => onPick(
                        id,
                        id == null
                            ? null
                            : '${options.firstWhere((o) => o['id'] == id)['name']}',
                      ),
                    ),
                  );
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      pick(
                        'Barangay',
                        list('barangays'),
                        barangayId,
                        (id, name) => setState(() {
                          barangayId = id;
                          barangayName = name;
                        }),
                      ),
                      pick(
                        'Disaster type',
                        list('disaster_types'),
                        disasterTypeId,
                        (id, name) => setState(() {
                          disasterTypeId = id;
                          disasterTypeName = name;
                        }),
                      ),
                    ],
                  );
                },
              ),
            Row(
              children: [
                TextButton(
                  onPressed: () => _apply(clear: true),
                  child: const Text('Clear'),
                ),
                const Spacer(),
                FilledButton(onPressed: _apply, child: const Text('Apply')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A record card on a page: leading icon, title lines, a tag on the right,
/// and widgets underneath (a button, a quantity).
class RecordCard extends StatelessWidget {
  final Widget leading;
  final String title;
  final List<String> lines;
  final Widget? tag;
  final List<Widget> actions;
  final VoidCallback? onTap;
  const RecordCard({
    super.key,
    required this.leading,
    required this.title,
    this.lines = const [],
    this.tag,
    this.actions = const [],
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return CswsCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              leading,
              Gaps.h12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                    for (final l in lines.where((l) => l.trim().isNotEmpty))
                      Text(l, style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
              if (tag != null) ...[
                Gaps.h8,
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 130),
                  child: tag!,
                ),
              ],
            ],
          ),
          if (actions.isNotEmpty) ...[
            Gaps.v12,
            Wrap(
              alignment: WrapAlignment.end,
              spacing: Space.xs,
              runSpacing: Space.xs,
              children: actions,
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Waiting to be received
// ---------------------------------------------------------------------------
class WaitingPage extends StatelessWidget {
  const WaitingPage({super.key});

  @override
  Widget build(BuildContext context) => CswsListPage(
    title: 'Waiting to be received',
    description: 'Pledged donations CSWS has not received yet.',
    path: '/dashboard/csws-main/waiting',
    countsPath: '/dashboard/csws-main/waiting/counts',
    chipParam: 'filter',
    chips: const [
      ListChip('', 'All', 'all'),
      ListChip('due', 'Due today or late', 'due'),
      ListChip('Drop Off', 'Drop Off', 'Drop Off'),
      ListChip('Door to Door', 'Door to Door', 'Door to Door'),
    ],
    sorts: const [
      ListSort('due_soonest', 'Due soonest'),
      ListSort('longest_waiting', 'Longest waiting'),
      ListSort('newest', 'Newest'),
    ],
    searchHint: 'Search item, report, barangay or QR',
    emptyTitle: 'Nothing waiting',
    emptyMessage: 'Pledged donations that CSWS has not received yet will show up here.',
    itemBuilder: (context, r, reload) => RecordCard(
      leading: ItemIcon(r['item_name'], category: r['item_category']),
      title: '${r['item_name']} · ${r['amount_text']}${_more(r['more_items'])}',
      lines: [
        '${r['report_label'] ?? ''} · ${r['barangay'] ?? ''} · ${r['handover_method'] ?? ''}',
        '${r['batch_reference']}',
        'Due ${shortDate(r['due_at'])} · waiting ${daysText(r['days_waiting']).toLowerCase()}',
      ],
      tag: r['late'] == true
          ? const CswsTag.overdue('Late')
          : r['due_today'] == true
          ? const CswsTag.overdue('Due today')
          : const CswsTag('Pending', icon: Icons.hourglass_empty),
      actions: [
        FilledButton.icon(
          onPressed: () async {
            await openDonationByQr(context, '${r['batch_reference']}');
            reload();
          },
          style: FilledButton.styleFrom(minimumSize: const Size(48, 44)),
          icon: const Icon(Icons.qr_code_scanner, size: 18),
          label: const Text('Receive'),
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Inventory: Summary | Per report (what CSWS received and still holds)
// ---------------------------------------------------------------------------
const _categoryChips = [
  ListChip('', 'All', 'all'),
  ListChip('food_water', 'Food & water', 'food_water'),
  ListChip('health', 'Health', 'health'),
  ListChip('shelter', 'Shelter', 'shelter'),
  ListChip('other', 'Other', 'other'),
];

/// One item in stock (Summary tab and one report's stock).
Widget _itemCard(BuildContext context, Map i) {
  final t = Theme.of(context).textTheme;
  final min = (i['min_stock'] as num?) ?? 0;
  return RecordCard(
    leading: ItemIcon(i['item_name'], category: i['category']),
    title: '${i['item_name']}',
    lines: [
      '${i['category'] ?? 'Other'}'
          '${min > 0 ? ' · minimum ${_n(min)} ${i['unit'] ?? ''}' : ''}',
      if (i['last_updated'] != null) 'Updated ${shortDate(i['last_updated'])}',
    ],
    tag: i['low'] == true
        ? const CswsTag('Low', kind: TagKind.serious)
        : const CswsTag('In stock'),
    actions: [
      Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: _n(i['quantity']),
              style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            TextSpan(text: ' ${i['unit'] ?? ''}', style: t.bodyLarge),
          ],
        ),
      ),
    ],
  );
}

class InventoryPage extends StatefulWidget {
  final bool perReport;
  const InventoryPage({super.key, this.perReport = false});

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> {
  late bool perReport = widget.perReport;

  @override
  Widget build(BuildContext context) {
    final tabs = Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: SegmentedButton<bool>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: false, label: Text('Summary')),
          ButtonSegment(value: true, label: Text('Per report')),
        ],
        selected: {perReport},
        onSelectionChanged: (s) => setState(() => perReport = s.first),
      ),
    );
    if (!perReport) {
      return CswsListPage(
        key: const ValueKey('inv-summary'),
        title: 'Inventory',
        description: 'Everything CSWS received and still holds, all reports added together.',
        path: '/inventory/summary',
        countsPath: '/inventory/summary/counts',
        chipParam: 'category',
        chips: _categoryChips,
        chipTitle: 'Category',
        placeFilters: true,
        sorts: const [
          ListSort('lowest', 'Lowest stock first'),
          ListSort('highest', 'Highest quantity'),
          ListSort('az', 'A–Z'),
          ListSort('last_updated', 'Last updated'),
        ],
        searchHint: 'Search item',
        emptyTitle: 'Inventory is empty',
        emptyMessage: 'Goods CSWS receives will show up here until they go out on a delivery.',
        top: [tabs],
        itemBuilder: (context, i, reload) => _itemCard(context, i),
      );
    }
    return CswsListPage(
      key: const ValueKey('inv-per-report'),
      title: 'Inventory',
      description: 'The stock CSWS holds for each disaster report.',
      path: '/inventory/per-report',
      countsPath: '/inventory/per-report/counts',
      placeFilters: true,
      sorts: const [
        ListSort('most_stock', 'Most stock first'),
        ListSort('newest', 'Newest report'),
        ListSort('barangay', 'Barangay A–Z'),
        ListSort('last_updated', 'Last updated'),
      ],
      searchHint: 'Search report or barangay',
      emptyTitle: 'No stock for any report',
      emptyMessage: 'Each report CSWS holds goods for will show up here.',
      top: [tabs],
      itemBuilder: (context, r, reload) => _ReportStockCard(r),
    );
  }
}

class _ReportStockCard extends StatelessWidget {
  final Map r;
  const _ReportStockCard(this.r);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final top = ((r['top_items'] as List?) ?? const []).cast<Map>();
    final more = ((r['stock_items'] as num?) ?? 0) - top.length;
    return CswsCard(
      onTap: () => _push(context, ReportStockPage(report: r)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const ItemIcon(null, asset: 'assets/item_icons/report.svg'),
              Gaps.h12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${r['report_label']} · ${r['barangay'] ?? ''}',
                      style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      [
                        '${_n(r['stock_items'])} ${r['stock_items'] == 1 ? 'item' : 'items'}'
                            ' · ${_n(r['stock_units'])} units',
                        if (r['last_updated'] != null) 'updated ${shortDate(r['last_updated'])}',
                      ].join(' · '),
                      style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
            ],
          ),
          if (top.isNotEmpty) ...[
            Gaps.v12,
            Wrap(
              spacing: Space.xs,
              runSpacing: Space.xs,
              children: [
                for (final i in top) _StockChip(i),
                if (more > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text('+$more more', style: t.bodyMedium),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _StockChip extends StatelessWidget {
  final Map i;
  const _StockChip(this.i);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          itemSvg(itemSvgAsset(i['item_name'], i['category']), 20),
          Gaps.h4,
          Flexible(
            child: Text(
              '${i['item_name']} ${_n(i['quantity'])} ${i['unit'] ?? ''}'.trim(),
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// The items CSWS holds for one report.
class ReportStockPage extends StatelessWidget {
  final Map report;
  const ReportStockPage({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    final id = report['report_id'];
    return CswsListPage(
      title: '${report['report_label']} · ${report['barangay'] ?? ''}',
      description: 'What CSWS received for this report and still holds.',
      path: '/inventory/per-report/$id',
      countsPath: '/inventory/per-report/$id/counts',
      chipParam: 'category',
      chips: _categoryChips,
      chipTitle: 'Category',
      sorts: const [
        ListSort('highest', 'Highest quantity'),
        ListSort('lowest', 'Lowest stock first'),
        ListSort('az', 'A–Z'),
        ListSort('last_updated', 'Last updated'),
      ],
      searchHint: 'Search item',
      emptyTitle: 'No stock here',
      emptyMessage: 'Items CSWS holds for this report will show up here.',
      itemBuilder: (context, i, reload) => _itemCard(context, i),
    );
  }
}
