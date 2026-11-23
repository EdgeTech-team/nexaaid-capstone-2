import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;

import '../../core/api.dart';
import 'widgets.dart';

// ---------------------------------------------------------------------------
// NF-003 (NEW FEATURE): one paged list for every module.
//
// Lists show 10 records per page with numbered pages (IT expert, UAT:
// "pagination"): "Showing 11–20 of 107" and ‹ 1 2 3 … 6 › under the list.
// Opening another page replaces the 20 rows on screen with the next 20.
//
// The backend answers `?limit=&offset=` with one page (a JSON array) and the
// number of matching rows in the X-Total-Count header (ApiResult.total).
// Page n is offset (n - 1) × 20.
//
//   final c = PagedController(
//     fetch: (offset, limit) => api.get('/things', query: {
//       'limit': '$limit', 'offset': '$offset', ...filters}),
//   );
//   PagedListView(controller: c, itemBuilder: ..., empty: ...);
//
// When a filter changes call c.refresh(fetch: <new fetch>): the list goes
// back to page 1, and a page still on its way for the old filter is dropped
// when it arrives, so it can never land in the new list.
//
// After a change elsewhere (an action, a live update) the page on screen is
// loaded again with reloadQuietly(): the rows stay until the fresh ones
// arrive, so nothing flashes and the user stays on the same page.
// ---------------------------------------------------------------------------

typedef PageFetch = Future<ApiResult> Function(int offset, int limit);

/// Records per page, everywhere (team decision: 10, so the page buttons
/// stay within a screen or two on a phone).
const defaultPageSize = 10;

class PagedController extends ChangeNotifier {
  PagedController({required PageFetch fetch, this.pageSize = defaultPageSize})
    : _fetchPage = fetch;

  PageFetch _fetchPage;
  final int pageSize;

  /// The rows of the page on screen, in the server's order.
  final List<Map> items = [];

  /// The page on screen (1 = first).
  int page = 1;

  /// Matching rows on the server (null until the first page arrives, or
  /// if the server sent no X-Total-Count).
  int? total;

  /// A page is on its way (the first one, or another page the user opened).
  bool isLoading = false;

  /// The failed request, or null. The rows already on screen stay.
  ApiResult? error;

  /// True once a first page arrived (for the empty state).
  bool loadedOnce = false;

  int _generation = 0;
  bool _disposed = false;

  /// The page the last request was for (Retry opens it again).
  int _asked = 1;

  /// Where the page on screen starts.
  int get offset => (page - 1) * pageSize;

  /// Number of pages, or null while the total is unknown.
  int? get pageCount =>
      total == null ? null : math.max(1, (total! + pageSize - 1) ~/ pageSize);

  bool get hasPrevious => page > 1;

  bool get hasNext {
    final n = pageCount;
    return n != null ? page < n : items.length == pageSize;
  }

  /// Load page 1 again: on open, pull-to-refresh, the web refresh button, or
  /// a filter change (pass the new [fetch]).
  Future<void> refresh({PageFetch? fetch}) {
    if (fetch != null) _fetchPage = fetch;
    items.clear();
    total = null;
    loadedOnce = false;
    return _load(1);
  }

  /// Open page [n] (1 = first). Out-of-range pages are ignored.
  Future<void> goTo(int n) {
    final last = pageCount;
    if (n < 1 ||
        (last != null && n > last) ||
        (n == page && loadedOnce && error == null)) {
      return Future.value();
    }
    return _load(n);
  }

  Future<void> next() => hasNext ? goTo(page + 1) : Future.value();
  Future<void> previous() => hasPrevious ? goTo(page - 1) : Future.value();

  /// Try the page that failed again, keeping the rows on screen.
  Future<void> retry() => _load(_asked);

  /// Load the page on screen again after a change elsewhere, keeping its
  /// rows until the fresh ones arrive. If the page is now past the end
  /// (its last rows were removed), the last page is shown instead. A failed
  /// quiet reload keeps the old rows and says nothing.
  Future<void> reloadQuietly() async {
    if (!loadedOnce) return refresh();
    final generation = ++_generation;
    final r = await _fetchPage(offset, pageSize);
    if (_disposed || generation != _generation) return;
    if (!r.ok || r.json is! List) return;
    final rows = (r.json as List).cast<Map>();
    total = r.total ?? total;
    if (rows.isEmpty && page > 1) {
      await _load(
        pageCount != null ? math.min(page - 1, pageCount!) : page - 1,
        quiet: true,
      );
      return;
    }
    items
      ..clear()
      ..addAll(rows);
    error = null;
    _notify();
  }

  /// Take rows out at once (e.g. the entry just acknowledged left the
  /// queue), then load the page again so it fills up from the next page.
  void removeWhere(bool Function(Map row) test) {
    final before = items.length;
    items.removeWhere(test);
    final gone = before - items.length;
    if (gone == 0) return;
    if (total != null) total = math.max(0, total! - gone);
    _notify();
    reloadQuietly();
  }

  Future<void> _load(int n, {bool quiet = false}) async {
    final generation = ++_generation;
    _asked = n;
    if (!quiet) {
      isLoading = true;
      error = null;
      _notify();
    }
    final r = await _fetchPage((n - 1) * pageSize, pageSize);
    // Disposed, or another page / filter asked for meanwhile: drop this one.
    if (_disposed || generation != _generation) return;
    isLoading = false;
    if (!r.ok || r.json is! List) {
      if (!quiet) error = r;
      _notify();
      return;
    }
    page = n;
    items
      ..clear()
      ..addAll((r.json as List).cast<Map>());
    total =
        r.total ?? (items.length < pageSize ? offset + items.length : total);
    loadedOnce = true;
    error = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// A list of 10 records per page with numbered pages under it, a loading
/// line while another page loads, an inline error + Retry that keeps the
/// rows on screen, and the screen's empty state. Pull down to refresh; the
/// web build also gets a refresh button.
///
/// While its tab or page is hidden (another bottom-menu tab, or a page
/// opened on top), changes are only noted; the page reloads quietly when it
/// shows again.
class PagedListView extends StatefulWidget {
  final PagedController controller;

  /// Widgets above the rows (title, filters); they scroll with the list.
  final List<Widget> header;

  /// A bar that stays at the top while the rows scroll (e.g. stage chips).
  final Widget? pinned;
  final double pinnedHeight;

  /// Widgets between the pinned bar and the rows (search, result count).
  final List<Widget> subheader;

  final Widget Function(BuildContext context, Map item) itemBuilder;

  /// Shown when there are no records.
  final Widget empty;

  /// What pull-to-refresh and the web refresh button do. Defaults to
  /// reloading the list from page 1.
  final Future<void> Function()? onRefresh;

  /// Also reload (quietly) when this fires, e.g. a live update.
  final Listenable? refresh;

  /// The screen's own controller, when it scrolls the list itself.
  final ScrollController? scrollController;

  final EdgeInsetsGeometry padding;

  const PagedListView({
    super.key,
    required this.controller,
    required this.itemBuilder,
    required this.empty,
    this.header = const [],
    this.pinned,
    this.pinnedHeight = 56,
    this.subheader = const [],
    this.onRefresh,
    this.refresh,
    this.scrollController,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  State<PagedListView> createState() => _PagedListViewState();
}

class _PagedListViewState extends State<PagedListView>
    with ShownState<PagedListView> {
  ScrollController? _own;
  ScrollController get _scroll =>
      widget.scrollController ?? (_own ??= ScrollController());

  /// The top of the rows, to bring into view when another page opens.
  final _rowsTop = GlobalKey();

  bool _stale = false;

  PagedController get c => widget.controller;

  Future<void> _refresh() => widget.onRefresh?.call() ?? c.refresh();

  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
    api.addListener(_elsewhere); // e.g. after an action
    widget.refresh?.addListener(_elsewhere);
    // First page after the first frame (the controller notifies at once,
    // and setState is not allowed during initState).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !c.loadedOnce && !c.isLoading) _refresh();
    });
  }

  @override
  void onShownAgain() {
    if (!_stale) return;
    _stale = false;
    c.reloadQuietly();
  }

  @override
  void didUpdateWidget(PagedListView old) {
    super.didUpdateWidget(old);
    if (old.controller != c) {
      old.controller.removeListener(_changed);
      c.addListener(_changed);
      // A new controller (e.g. another stage or filter set) starts at
      // page 1; without this it would show the loading cards forever.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !c.loadedOnce && !c.isLoading) c.refresh();
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
    if (old.refresh != widget.refresh) {
      old.refresh?.removeListener(_elsewhere);
      widget.refresh?.addListener(_elsewhere);
    }
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    api.removeListener(_elsewhere);
    widget.refresh?.removeListener(_elsewhere);
    _own?.dispose();
    super.dispose();
  }

  /// Something changed elsewhere: reload the page quietly now, or when the
  /// list shows again.
  void _elsewhere() {
    if (!mounted) return;
    if (!shown) {
      _stale = true;
      return;
    }
    c.reloadQuietly();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Open page [n] and bring the top of the rows into view (the visitor may
  /// be at the bottom of the list, at the page buttons).
  void _open(int n) {
    c.goTo(n);
    final ctx = _rowsTop.currentContext;
    final box = ctx?.findRenderObject();
    if (box == null || !_scroll.hasClients) return;
    final p = _scroll.position;
    final pinned = widget.pinned != null ? widget.pinnedHeight : 0.0;
    final top =
        RenderAbstractViewport.of(box).getOffsetToReveal(box, 0).offset -
        pinned -
        8;
    if (top >= p.pixels) return; // already in view
    final to = top.clamp(0.0, p.maxScrollExtent);
    if (MediaQuery.disableAnimationsOf(context)) {
      _scroll.jumpTo(to);
    } else {
      _scroll.animateTo(
        to,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// Under the rows: errors, the empty state, "Showing 11–20 of 107" and the
  /// page buttons.
  Widget _footer(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final error = c.error;
    if (error != null && c.items.isEmpty) {
      return ErrorView.forStatus(
        error.status,
        error.errorText,
        onRetry: c.retry,
      );
    }
    if (!c.loadedOnce && c.items.isEmpty) {
      return const Column(children: [SkeletonCard(), Gaps.v12, SkeletonCard()]);
    }
    if (c.loadedOnce && c.items.isEmpty) return widget.empty;

    final total = c.total;
    final from = c.offset + 1;
    final to = c.offset + c.items.length;
    final pages = c.pageCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (error != null)
          Padding(
            key: const ValueKey('paged-error'),
            padding: const EdgeInsets.only(top: Space.sm),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    error.status == 0
                        ? "Couldn't open that page. Check the connection."
                        : "Couldn't open that page: ${error.errorText}",
                    style: t.bodySmall?.copyWith(color: cs.error),
                  ),
                ),
                TextButton.icon(
                  onPressed: c.retry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: Space.md),
          child: Text(
            total == null ? 'Showing $from–$to' : 'Showing $from–$to of $total',
            key: const ValueKey('paged-range'),
            textAlign: TextAlign.center,
            style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
        if (c.hasPrevious || c.hasNext)
          Padding(
            padding: const EdgeInsets.only(top: Space.sm),
            child: Pager(
              page: c.page,
              pageCount: pages,
              hasNext: c.hasNext,
              enabled: !c.isLoading,
              onPage: _open,
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final header = [
      if (kIsWeb)
        Align(
          alignment: Alignment.centerRight,
          child: IconButton(
            key: const ValueKey('paged-refresh'),
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: c.isLoading ? null : _refresh,
          ),
        ),
      ...widget.header,
    ];
    final rows = c.items;
    final pad = widget.padding.resolve(Directionality.of(context));
    final pinned = widget.pinned;
    // Another page is on its way: the rows on screen fade until it arrives.
    final switching = c.isLoading && c.loadedOnce;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: pad.copyWith(bottom: 0),
            sliver: SliverList.list(children: header),
          ),
          if (pinned != null)
            SliverPersistentHeader(
              pinned: true,
              delegate: _PinnedBar(pinned, widget.pinnedHeight),
            ),
          if (widget.subheader.isNotEmpty)
            SliverPadding(
              padding: EdgeInsets.fromLTRB(pad.left, Space.sm, pad.right, 0),
              sliver: SliverList.list(children: widget.subheader),
            ),
          SliverToBoxAdapter(
            key: _rowsTop,
            child: SizedBox(
              height: 3,
              child: switching
                  ? const LinearProgressIndicator(
                      key: ValueKey('paged-loading'),
                    )
                  : null,
            ),
          ),
          SliverPadding(
            padding: pad.copyWith(top: pinned != null ? Space.sm : 4),
            sliver: SliverList.builder(
              itemCount: rows.length + 1,
              itemBuilder: (context, i) {
                if (i == rows.length) return _footer(context);
                return AnimatedOpacity(
                  opacity: switching ? 0.4 : 1,
                  duration: const Duration(milliseconds: 150),
                  child: IgnorePointer(
                    ignoring: switching,
                    child: widget.itemBuilder(context, rows[i]),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Page buttons. Wide screens: ‹ Previous  1 … 4 [5] 6 … 12  Next ›.
/// Phones: ‹  Page 5 of 12  › with large tap targets.
class Pager extends StatelessWidget {
  final int page;

  /// null while the total is unknown (then only Previous / Next).
  final int? pageCount;
  final bool hasNext;
  final bool enabled;
  final ValueChanged<int> onPage;

  const Pager({
    super.key,
    required this.page,
    required this.pageCount,
    required this.hasNext,
    required this.onPage,
    this.enabled = true,
  });

  /// The page numbers to show, with null for "…": first, last, and the
  /// pages around the current one.
  static List<int?> numbers(int page, int count) {
    if (count <= 7) return [for (var i = 1; i <= count; i++) i];
    final show = <int>{1, count, page - 1, page, page + 1};
    if (page <= 3) show.addAll([2, 3, 4]);
    if (page >= count - 2) show.addAll([count - 3, count - 2, count - 1]);
    final sorted = show.where((n) => n >= 1 && n <= count).toList()..sort();
    final out = <int?>[];
    for (final n in sorted) {
      if (out.isNotEmpty && out.last != null && n - out.last! > 1) {
        out.add(null);
      }
      out.add(n);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final count = pageCount;
    final prev = enabled && page > 1 ? () => onPage(page - 1) : null;
    final next = enabled && hasNext ? () => onPage(page + 1) : null;

    return Semantics(
      container: true,
      label: count == null
          ? 'Pages, page $page'
          : 'Pages, page $page of $count',
      child: LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= 560 && count != null;
          if (!wide) {
            return Row(
              key: const ValueKey('pager-compact'),
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton.outlined(
                  key: const ValueKey('pager-prev'),
                  tooltip: 'Previous page',
                  onPressed: prev,
                  icon: const Icon(Icons.chevron_left),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.md),
                  child: Text(
                    count == null ? 'Page $page' : 'Page $page of $count',
                    style: t.titleSmall,
                  ),
                ),
                IconButton.outlined(
                  key: const ValueKey('pager-next'),
                  tooltip: 'Next page',
                  onPressed: next,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            );
          }
          return Wrap(
            key: const ValueKey('pager-numbers'),
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            runSpacing: 4,
            children: [
              TextButton.icon(
                key: const ValueKey('pager-prev'),
                onPressed: prev,
                icon: const Icon(Icons.chevron_left),
                label: const Text('Previous'),
              ),
              for (final n in numbers(page, count))
                if (n == null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(
                      '…',
                      style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  )
                else if (n == page)
                  Semantics(
                    selected: true,
                    label: 'Page $n, current page',
                    child: FilledButton(
                      key: ValueKey('pager-page-$n'),
                      onPressed: null,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(44, 44),
                        padding: EdgeInsets.zero,
                        disabledBackgroundColor: cs.primary,
                        disabledForegroundColor: cs.onPrimary,
                      ),
                      child: Text('$n'),
                    ),
                  )
                else
                  OutlinedButton(
                    key: ValueKey('pager-page-$n'),
                    onPressed: enabled ? () => onPage(n) : null,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(44, 44),
                      padding: EdgeInsets.zero,
                    ),
                    child: Text('$n', semanticsLabel: 'Page $n'),
                  ),
              TextButton(
                key: const ValueKey('pager-next'),
                onPressed: next,
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Next'),
                    SizedBox(width: 4),
                    Icon(Icons.chevron_right),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A bar that stays at the top of the list while it scrolls.
class _PinnedBar extends SliverPersistentHeaderDelegate {
  final Widget child;
  final double height;
  const _PinnedBar(this.child, this.height);

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) =>
      Material(
        color: Theme.of(context).scaffoldBackgroundColor,
        elevation: overlaps ? 2 : 0,
        child: Align(alignment: Alignment.centerLeft, child: child),
      );

  @override
  bool shouldRebuild(_PinnedBar old) => true;
}
