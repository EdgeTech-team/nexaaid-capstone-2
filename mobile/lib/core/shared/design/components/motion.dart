import 'package:flutter/material.dart';

import '../tokens.dart';

/// Fades a child in and slides it up 16 px, once, when it first appears.
/// [index] staggers a group: 0 starts first, 1 starts 70 ms later, etc.
/// Does nothing when the phone's "remove animations" setting is on.
class EntranceMotion extends StatefulWidget {
  final Widget child;
  final int index;
  const EntranceMotion({super.key, required this.child, this.index = 0});

  @override
  State<EntranceMotion> createState() => _EntranceMotionState();
}

class _EntranceMotionState extends State<EntranceMotion>
    with SingleTickerProviderStateMixin {
  static const _step = Duration(milliseconds: 70);
  static const _run = Duration(milliseconds: 450);

  late final AnimationController _c;
  late final Animation<double> _t;

  @override
  void initState() {
    super.initState();
    final total = _run + _step * widget.index;
    _c = AnimationController(vsync: this, duration: total)..forward();
    final start = (_step * widget.index).inMilliseconds / total.inMilliseconds;
    _t = CurvedAnimation(
      parent: _c,
      curve: Interval(start, 1, curve: Motion.curve),
    );
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;
    return AnimatedBuilder(
      animation: _t,
      child: widget.child,
      builder: (_, child) => Opacity(
        opacity: _t.value,
        child: Transform.translate(
          offset: Offset(0, 16 * (1 - _t.value)),
          child: child,
        ),
      ),
    );
  }
}

/// A Column whose children enter one after another.
/// Gaps (SizedBox) appear immediately and don't count in the order.
class StaggeredColumn extends StatelessWidget {
  final List<Widget> children;
  final CrossAxisAlignment crossAxisAlignment;
  final MainAxisSize mainAxisSize;

  const StaggeredColumn({
    super.key,
    required this.children,
    this.crossAxisAlignment = CrossAxisAlignment.center,
    this.mainAxisSize = MainAxisSize.max,
  });

  @override
  Widget build(BuildContext context) {
    var i = 0;
    return Column(
      crossAxisAlignment: crossAxisAlignment,
      mainAxisSize: mainAxisSize,
      children: [
        for (final c in children)
          c is SizedBox ? c : EntranceMotion(index: i++, child: c),
      ],
    );
  }
}

/// Counts a number up from 0, e.g. "1,284". Text that isn't a whole
/// number (like "45%") is shown as is.
class CountUpText extends StatelessWidget {
  final String value;
  final TextStyle? style;
  const CountUpText(this.value, {super.key, this.style});

  @override
  Widget build(BuildContext context) {
    final n = int.tryParse(value.replaceAll(',', ''));
    if (n == null || MediaQuery.disableAnimationsOf(context)) {
      return Text(value, style: style);
    }
    final commas = value.contains(',');
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: n.toDouble()),
      duration: const Duration(milliseconds: 900),
      curve: Motion.curve,
      builder: (_, v, _) => Text(_format(v.round(), commas), style: style),
    );
  }

  static String _format(int n, bool commas) => commas
      ? n.toString().replaceAllMapped(
          RegExp(r'\B(?=(\d{3})+(?!\d))'),
          (_) => ',',
        )
      : '$n';
}
