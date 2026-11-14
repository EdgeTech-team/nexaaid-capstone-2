import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import 'widgets.dart';

// ---------------------------------------------------------------------------
// NF-003 (NEW FEATURE): one paged list for every module.
//
// The backend answers `?limit=&offset=` with one page (a JSON array) and the
// number of matching rows in the X-Total-Count header (ApiResult.total).
//
//   final c = PagedController(
//     fetch: (offset, limit) => api.get('/things', query: {
//       'limit': '$limit', 'offset': '$offset', ...filters}),
//   );
//   PagedListView(controller: c, itemBuilder: ..., empty: ...);
//
// When a filter changes call c.refresh(fetch: <new fetch>): the list starts
// again from page 1, and a page still on its way for the old filter is
// dropped when it arrives, so it can never land in the new list.
//
// After a change elsewhere (an action, a live update) the list is loaded
// again with reloadQuietly(): the rows stay on screen until the fresh ones
// arrive, so nothing flashes and the scroll position is kept (UAT, Nov 14).
// ---------------------------------------------------------------------------

typedef PageFetch = Future<ApiResult> Function(int offset, int limit);

/// The most rows the backend sends in one page (core/pagination.py
/// MAX_LIMIT); a quiet reload asks for at most this many.
const maxPageRows = 100;

class PagedController extends ChangeNotifier {
  PagedController({required PageFetch fetch, this.pageSize = 20})
    : _fetchPage = fetch;

  PageFetch _fetchPage;
  final int pageSize;

  /// The rows loaded so far, in the server's order.
  final List<Map> items = [];

  /// Where the next page starts.
  int offset = 0;

  /// Matching rows on the server (null until the first page arrives, or
  /// if the server sent no X-Total-Count).
  int? total;

  bool isLoading = false;

  /// The failed request, or null. Rows already loaded stay.
  ApiResult? error;

  /// True once a first page arrived (for the empty state).
  bool loadedOnce = false;

  bool _lastPageSeen = false;
  bool _quiet = false;
  int _generation = 0;
  bool _disposed = false;

  bool get hasMore =>
      !_lastPageSeen && (total == null || items.length < total!);

  /// Load page 1 again: on open, pull-to-refresh, the web refresh button, or
  /// a filter change (pass the new [fetch]).
  Future<void> refresh({PageFetch? fetch}) {
    if (fetch != null) _fetchPage = fetch;
    _generation++;
    items.clear();
    offset = 0;
    total = null;
    error = null;
    loadedOnce = false;
    _lastPageSeen = false;
    _quiet = false;
    isLoading = false;
    return _load();
  }

  /// Load the rows already shown again (up to [maxPageRows]) after a change
  /// elsewhere, keeping them on screen until the fresh ones arrive. A failed
  /// quiet reload keeps the old rows and says nothing.
  Future<void> reloadQuietly() async {
    if (!loadedOnce || items.isEmpty) return refresh();
    final generation = ++_generation; // a page on its way is dropped
    _quiet = true;
    isLoading = false;
    final limit = items.length.clamp(pageSize, maxPageRows);
    final r = await _fetchPage(0, limit);
    if (_disposed || generation != _generation) return;
    _quiet = false;
    if (r.ok && r.json is List) {
      final page = (r.json as List).cast<Map>();
      items
        ..clear()
        ..addAll(page);
      offset = page.length;
      total = r.total ?? (page.length < limit ? page.length : total);
      _lastPageSeen = page.length < limit;
      error = null;
    }
    _notify();
  }

  /// Take rows out at once (e.g. the entry just acknowledged left the
  /// queue), without waiting for the server. The next page starts that
  /// many rows earlier, as the server no longer counts them either.
  void removeWhere(bool Function(Map row) test) {
    final before = items.length;
    items.removeWhere(test);
    final gone = before - items.length;
    if (gone == 0) return;
    offset = math.max(0, offset - gone);
    if (total != null) total = math.max(0, total! - gone);
    _notify();
  }

  /// Load the next page. Does nothing while a page is loading, after the
  /// last page, or after an error (the user taps Retry instead).
  Future<void> loadMore() {
    if (isLoading || _quiet || !hasMore || error != null) {
      return Future.value();
    }
    return _load();
  }

  /// Try the failed page again, keeping the rows already loaded.
  Future<void> retry() {
    if (isLoading) return Future.value();
    error = null;
    return _load();
  }

  Future<void> _load() async {
    final generation = _generation;
    isLoading = true;
    error = null;
    _notify();
    final r = await _fetchPage(offset, pageSize);
    // Disposed, or refreshed for another filter meanwhile: drop this page.
    if (_disposed || generation != _generation) return;
    isLoading = false;
    if (!r.ok || r.json is! List) {
      error = r;
      _notify();
      return;
    }
    final page = (r.json as List).cast<Map>();
    items.addAll(page);
    offset += page.length;
    total = r.total ?? total;
    if (page.length < pageSize) _lastPageSeen = true;
    loadedOnce = true;
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

/// A scrolling list that loads the next page well before the bottom, with
/// a placeholder card while fetching, an inline error + Retry that keeps
/// loaded rows, an end-of-list line, and the screen's empty state. Pull
/// down to refresh; the web build also gets a refresh button.
///
/// While its tab or page is hidden (another bottom-menu tab, or a page
/// opened on top), changes are only noted; the list reloads quietly when it
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

  /// Shown when the first page is empty.
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

  /// Start the next page this far from the bottom (at least 1200 px, or
  /// two and a half screens), so it is usually there before it is reached.
  double get _nearBottom => math.max(
    1200.0,
    _scroll.hasClients && _scroll.position.hasViewportDimension
        ? _scroll.position.viewportDimension * 2.5
        : 0,
  );

  bool _stale = false;

  /// The rows' sliver. Rows added while the bottom of the list is still
  /// off screen (the next page arrives early) change no built child, so the
  /// sliver would keep the old length and the list would stop scrolling
  /// there; it is told to measure itself again whenever rows change.
  final _rowsKey = GlobalKey();
  int _shown = 0;

  PagedController get c => widget.controller;

  Future<void> _refresh() => widget.onRefresh?.call() ?? c.refresh();

  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
    _scroll.addListener(_maybeLoadMore);
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
    if (old.scrollController != widget.scrollController) {
      (old.scrollController ?? _own)?.removeListener(_maybeLoadMore);
      _scroll.addListener(_maybeLoadMore);
    }
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    api.removeListener(_elsewhere);
    widget.refresh?.removeListener(_elsewhere);
    _scroll.removeListener(_maybeLoadMore);
    _own?.dispose();
    super.dispose();
  }

  /// Something changed elsewhere: reload quietly now, or when shown again.
  void _elsewhere() {
    if (!mounted) return;
    if (!shown) {
      _stale = true;
      return;
    }
    c.reloadQuietly();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (c.items.length != _shown) {
      _shown = c.items.length;
      _rowsKey.currentContext?.findRenderObject()?.markNeedsLayout();
    }
    // A short page (or a tall screen on the web) may not scroll at all:
    // keep loading until the screen is filled or the list ends.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadMore());
  }

  void _maybeLoadMore() {
    if (!mounted || !_scroll.hasClients || !c.loadedOnce) return;
    // Not laid out (a page on top, or a hidden tab): no size to check yet.
    final p = _scroll.position;
    if (!p.hasContentDimensions || !p.hasViewportDimension) return;
    if (p.extentAfter < _nearBottom) c.loadMore();
  }

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
    if (error != null) {
      return Padding(
        key: const ValueKey('paged-error'),
        padding: const EdgeInsets.symmetric(vertical: Space.sm),
        child: Row(
          children: [
            Expanded(
              child: Text(
                error.status == 0
                    ? "Couldn't load more. Check the connection."
                    : "Couldn't load more: ${error.errorText}",
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
      );
    }
    if (!c.loadedOnce && c.items.isEmpty) {
      return const Column(children: [SkeletonCard(), Gaps.v12, SkeletonCard()]);
    }
    if (c.isLoading) {
      // The next rows' place, instead of a spinner at the very bottom.
      return const Padding(
        key: ValueKey('paged-loading'),
        padding: EdgeInsets.only(top: Space.sm),
        child: SkeletonCard(),
      );
    }
    if (c.loadedOnce && c.items.isEmpty) return widget.empty;
    if (c.loadedOnce && !c.hasMore) {
      final n = c.total ?? c.items.length;
      return Padding(
        key: const ValueKey('paged-end'),
        padding: const EdgeInsets.symmetric(vertical: Space.md),
        child: Text(
          n == 1 ? 'That is the only one.' : 'That is all $n.',
          textAlign: TextAlign.center,
          style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
      );
    }
    return const SizedBox.shrink();
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
          SliverPadding(
            padding: pad.copyWith(top: pinned != null ? Space.sm : 0),
            sliver: SliverList.builder(
              key: _rowsKey,
              itemCount: rows.length + 1,
              itemBuilder: (context, i) => i < rows.length
                  ? widget.itemBuilder(context, rows[i])
                  : _footer(context),
            ),
          ),
        ],
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
