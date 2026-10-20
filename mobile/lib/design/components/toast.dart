import 'package:flutter/material.dart';

import '../tokens.dart';

// ---------------------------------------------------------------------------
// Toasts (testing fix, UI notifications).
//
// The old bottom SnackBar covered the form, and the one with a "View" button
// ("Report validated") never closed: Flutter keeps a SnackBar that has an
// action open until it is tapped. Toasts replace it:
//   * shown at the top (top-right on tablets / Chrome), so they never sit on
//     the fields or the keyboard;
//   * an X on every toast, and swipe sideways to dismiss;
//   * close by themselves after a while, with a thin bar showing the time
//     left. The timer pauses while the pointer is over the toast or a finger
//     is on it, and starts again when they leave;
//   * at most 3 at a time, newest on top; the same message is not stacked
//     twice;
//   * read out by screen readers (live region).
//
//   AppToast.success(context, 'Report #12 validated');
//   AppToast.error(context, 'Cannot reach the server');
//   AppToast.show(context, 'Delivery #4 is now In Transit',
//       title: 'Delivery update', action: ToastAction('View', open));
// ---------------------------------------------------------------------------

enum ToastKind { success, error, warning, info }

class ToastAction {
  final String label;
  final VoidCallback onPressed;
  const ToastAction(this.label, this.onPressed);
}

class _ToastData {
  final int id;
  final ToastKind kind;
  final String? title;
  final String message;
  final ToastAction? action;
  final Duration duration;
  _ToastData(
    this.id,
    this.kind,
    this.title,
    this.message,
    this.action,
    this.duration,
  );
}

abstract final class AppToast {
  /// Most toasts on screen at once. Older ones go first.
  static const maxVisible = 3;

  static final _items = ValueNotifier<List<_ToastData>>(const []);
  static OverlayEntry? _entry;
  static OverlayState? _overlay;
  static int _nextId = 0;

  /// How long a toast stays when nobody touches it. Errors and toasts with
  /// a button stay longer, so there is time to read or tap.
  static Duration durationFor(ToastKind kind, {bool hasAction = false}) {
    final base = switch (kind) {
      ToastKind.success => const Duration(seconds: 4),
      ToastKind.info => const Duration(seconds: 5),
      ToastKind.warning => const Duration(seconds: 6),
      ToastKind.error => const Duration(seconds: 7),
    };
    return hasAction ? base + const Duration(seconds: 3) : base;
  }

  static void show(
    BuildContext context,
    String message, {
    ToastKind kind = ToastKind.info,
    String? title,
    ToastAction? action,
    Duration? duration,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    showOn(
      overlay,
      message,
      kind: kind,
      title: title,
      action: action,
      duration: duration,
    );
  }

  /// Same as [show], for code that looked up the overlay before an `await`
  /// (the screen may be gone by the time the answer comes back).
  static void showOn(
    OverlayState overlay,
    String message, {
    ToastKind kind = ToastKind.info,
    String? title,
    ToastAction? action,
    Duration? duration,
  }) {
    if (!overlay.mounted) return;
    _ensureHost(overlay);
    final data = _ToastData(
      _nextId++,
      kind,
      title,
      message,
      action,
      duration ?? durationFor(kind, hasAction: action != null),
    );
    final list = [
      for (final t in _items.value)
        if (!(t.message == message && t.title == title)) t,
      data,
    ];
    _items.value = list.length > maxVisible
        ? list.sublist(list.length - maxVisible)
        : list;
  }

  static void success(BuildContext context, String message, {String? title}) =>
      show(context, message, kind: ToastKind.success, title: title);

  static void error(BuildContext context, String message, {String? title}) =>
      show(context, message, kind: ToastKind.error, title: title);

  static void info(
    BuildContext context,
    String message, {
    String? title,
    ToastAction? action,
  }) => show(context, message, title: title, action: action);

  /// Removes every toast of the kinds [test] accepts (no animation).
  static void dismissWhere(bool Function(ToastKind kind) test) {
    final keep = [
      for (final t in _items.value)
        if (!test(t.kind)) t,
    ];
    if (keep.length != _items.value.length) _items.value = keep;
  }

  static void dismissAll() => dismissWhere((_) => true);

  /// Number of toasts on screen (for tests).
  static int get visibleCount => _items.value.length;

  static void _remove(int id) {
    _items.value = [
      for (final t in _items.value)
        if (t.id != id) t,
    ];
  }

  static void _ensureHost(OverlayState overlay) {
    // Already inserted in this overlay. (Not `_entry!.mounted`: that only
    // turns true on the next frame, so two toasts shown at the same moment
    // used to reset the list and lose the first one.)
    if (_entry != null && identical(_overlay, overlay)) return;
    if (_entry?.mounted ?? false) _entry!.remove();
    _items.value = const [];
    _overlay = overlay;
    _entry = OverlayEntry(builder: (_) => const _ToastHost());
    overlay.insert(_entry!);
  }
}

/// Lays the toasts out at the top. Only the toasts take taps; the rest of
/// the screen stays usable.
class _ToastHost extends StatelessWidget {
  const _ToastHost();

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final wide = mq.size.width >= Breakpoints.medium;
    return ValueListenableBuilder<List<_ToastData>>(
      valueListenable: AppToast._items,
      builder: (context, items, _) {
        if (items.isEmpty) return const SizedBox.shrink();
        return Stack(
          children: [
            Positioned(
              top: mq.padding.top + Space.xs,
              right: wide ? Space.md : Space.sm,
              left: wide ? null : Space.sm,
              width: wide ? 400 : null,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final t in items.reversed) // newest first
                    Padding(
                      key: ValueKey(t.id),
                      padding: const EdgeInsets.only(bottom: Space.xs),
                      child: _ToastCard(t),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ToastCard extends StatefulWidget {
  final _ToastData data;
  const _ToastCard(this.data);

  @override
  State<_ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<_ToastCard> with TickerProviderStateMixin {
  /// Slide-and-fade in / out.
  late final AnimationController _shown = AnimationController(
    vsync: this,
    duration: Motion.normal,
  );

  /// Time left before it closes by itself (0 -> 1).
  late final AnimationController _life = AnimationController(
    vsync: this,
    duration: widget.data.duration,
  );

  bool _closing = false;
  bool _hovered = false;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _life.addStatusListener((s) {
      if (s == AnimationStatus.completed) _close();
    });
    _shown.forward().whenComplete(() {
      if (mounted && !_closing) _life.forward();
    });
  }

  @override
  void dispose() {
    _shown.dispose();
    _life.dispose();
    super.dispose();
  }

  void _pauseOrResume() {
    if (_closing) return;
    if (_hovered || _pressed) {
      _life.stop();
    } else if (_shown.isCompleted) {
      _life.forward();
    }
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    _life.stop();
    if (!MediaQuery.disableAnimationsOf(context)) {
      await _shown.reverse();
    }
    AppToast._remove(widget.data.id);
  }

  (Color, IconData) _look(ColorScheme cs) => switch (widget.data.kind) {
    ToastKind.success => (AppColors.success, Icons.check_circle_rounded),
    ToastKind.error => (cs.error, Icons.error_rounded),
    ToastKind.warning => (const Color(0xFFB7791F), Icons.warning_amber_rounded),
    ToastKind.info => (cs.primary, Icons.info_rounded),
  };

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final (accent, icon) = _look(cs);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion && !_shown.isCompleted && !_closing) _shown.value = 1;

    final card = Material(
      color: cs.surfaceContainerHigh,
      elevation: 6,
      shadowColor: Colors.black38,
      borderRadius: BorderRadius.circular(Radii.md),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: accent, width: 4)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.sm,
                Space.sm,
                Space.xxs,
                Space.sm,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.14),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, size: 20, color: accent),
                  ),
                  Gaps.h12,
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (d.title != null) ...[
                            Text(
                              d.title!,
                              style: t.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: cs.onSurface,
                              ),
                            ),
                            Gaps.v4,
                          ],
                          Text(
                            d.message,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style:
                                (d.title == null ? t.bodyMedium : t.bodySmall)
                                    ?.copyWith(
                                      color: d.title == null
                                          ? cs.onSurface
                                          : cs.onSurfaceVariant,
                                      fontWeight: d.title == null
                                          ? FontWeight.w600
                                          : null,
                                    ),
                          ),
                          if (d.action != null) ...[
                            Gaps.v4,
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton(
                                style: TextButton.styleFrom(
                                  foregroundColor: accent,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: Space.xs,
                                  ),
                                  minimumSize: const Size(0, 36),
                                  textStyle: t.labelLarge?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                onPressed: () {
                                  _close();
                                  d.action!.onPressed();
                                },
                                child: Text(d.action!.label),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Dismiss',
                    visualDensity: VisualDensity.compact,
                    iconSize: 20,
                    color: cs.onSurfaceVariant,
                    onPressed: _close,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            // Time left before it closes by itself.
            AnimatedBuilder(
              animation: _life,
              builder: (context, child) => LinearProgressIndicator(
                value: 1 - _life.value,
                minHeight: 3,
                color: accent.withValues(alpha: 0.7),
                backgroundColor: Colors.transparent,
              ),
            ),
          ],
        ),
      ),
    );

    final animated = AnimatedBuilder(
      animation: _shown,
      builder: (context, child) {
        final v = Motion.curve.transform(_shown.value);
        return Opacity(
          opacity: v,
          child: Transform.translate(
            offset: Offset(0, -16 * (1 - v)),
            child: child,
          ),
        );
      },
      child: card,
    );

    return Semantics(
      container: true,
      liveRegion: true,
      child: MouseRegion(
        onEnter: (_) {
          _hovered = true;
          _pauseOrResume();
        },
        onExit: (_) {
          _hovered = false;
          _pauseOrResume();
        },
        child: Listener(
          onPointerDown: (_) {
            _pressed = true;
            _pauseOrResume();
          },
          onPointerUp: (_) {
            _pressed = false;
            _pauseOrResume();
          },
          onPointerCancel: (_) {
            _pressed = false;
            _pauseOrResume();
          },
          child: Dismissible(
            key: ValueKey('toast-${d.id}'),
            direction: DismissDirection.horizontal,
            onDismissed: (_) {
              _closing = true;
              AppToast._remove(d.id);
            },
            child: animated,
          ),
        ),
      ),
    );
  }
}
