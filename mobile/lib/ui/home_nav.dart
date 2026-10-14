import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Oct 11 notes (Jenises): tapping a notification moves to the page that
// already exists in the app (a tab of the bottom menu, with the right view
// inside it), instead of opening a second copy of that page on top.
//
//   HomeNav.go(context, HomeTarget('Validate', view: 'Pending', id: 12));
//
// closes the pages opened on top (e.g. the inbox), switches the bottom menu
// to that tab, and the tab's screen opens on the asked view. `then` runs
// once the tab is showing, for a pop-up over it (a report summary, a
// donation sheet) or a detail page that is normally opened from that tab.
// ---------------------------------------------------------------------------

class HomeTarget {
  /// The tab label, as in the bottom menu ("Validate", "Accounts", ...).
  final String tab;

  /// A view inside the tab, e.g. 'registrations' in Accounts.
  final String? view;

  /// The item it is about (report id, ...), for screens that point it out.
  final int? id;

  /// Runs after the tab is showing, with the app's main context.
  final void Function(BuildContext context)? then;

  const HomeTarget(this.tab, {this.view, this.id, this.then});
}

abstract final class HomeNav {
  static final target = ValueNotifier<_Request?>(null);
  static int _seq = 0;
  static final Map<String, int> _taken = {};

  /// Go to [to]: close the pages on top and show that tab.
  static void go(BuildContext context, HomeTarget to) {
    Navigator.of(context).popUntil((r) => r.isFirst);
    target.value = _Request(++_seq, to);
  }

  /// The latest target for [tab], once. Tab screens call this when they
  /// open and when [target] changes while they are showing.
  static HomeTarget? take(String tab) {
    final r = target.value;
    if (r == null || r.to.tab != tab || _taken[tab] == r.seq) return null;
    _taken[tab] = r.seq;
    return r.to;
  }
}

class _Request {
  final int seq;
  final HomeTarget to;
  const _Request(this.seq, this.to);
}

/// For tab screens that can open on a given view: [applyHomeTarget] runs
/// when the screen opens because of a notification, and again if one
/// arrives while the screen is already showing.
mixin HomeTargetListener<T extends StatefulWidget> on State<T> {
  String get homeTab;
  void applyHomeTarget(HomeTarget target);

  @override
  void initState() {
    super.initState();
    final t = HomeNav.take(homeTab);
    if (t != null) applyHomeTarget(t);
    HomeNav.target.addListener(_onTarget);
  }

  void _onTarget() {
    final t = HomeNav.take(homeTab);
    if (t != null && mounted) setState(() => applyHomeTarget(t));
  }

  @override
  void dispose() {
    HomeNav.target.removeListener(_onTarget);
    super.dispose();
  }
}
