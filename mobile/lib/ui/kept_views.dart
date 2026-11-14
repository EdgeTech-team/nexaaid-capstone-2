import 'package:flutter/material.dart';

/// UAT (Nov 14): sub-tabs (Donations / Per report / ..., Validated / Status)
/// opened once stay alive, like the bottom-menu tabs in home.dart, so
/// switching back shows them at once, where they were left. Hidden views
/// take no taps, focus or animation frames, and their lists reload quietly
/// when shown again if something changed meanwhile (Loader, PagedListView).
///
///   KeptViews(current: view, builder: (context, v) => switch (v) {...})
///
/// A new [resetKey] (e.g. a filter every view uses) drops the kept views,
/// so each one loads again for it when opened.
class KeptViews extends StatefulWidget {
  final String current;
  final Widget Function(BuildContext context, String view) builder;
  final Object? resetKey;

  const KeptViews({
    super.key,
    required this.current,
    required this.builder,
    this.resetKey,
  });

  @override
  State<KeptViews> createState() => _KeptViewsState();
}

class _KeptViewsState extends State<KeptViews> {
  late final List<String> _opened = [widget.current];
  final Map<String, ScrollController> _scrolls = {};

  @override
  void didUpdateWidget(KeptViews old) {
    super.didUpdateWidget(old);
    if (old.resetKey != widget.resetKey) _opened.clear();
    if (!_opened.contains(widget.current)) _opened.add(widget.current);
  }

  @override
  void dispose() {
    for (final c in _scrolls.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      for (final v in _opened)
        Offstage(
          key: ValueKey('$v-${widget.resetKey}'),
          offstage: v != widget.current,
          child: TickerMode(
            enabled: v == widget.current,
            child: ExcludeFocus(
              excluding: v != widget.current,
              // Each view its own primary scroll controller, so hidden lists
              // never share one with the view on screen.
              child: PrimaryScrollController(
                controller: _scrolls.putIfAbsent(v, ScrollController.new),
                child: widget.builder(context, v),
              ),
            ),
          ),
        ),
    ],
  );
}
