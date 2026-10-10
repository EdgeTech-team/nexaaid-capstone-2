import 'package:flutter/foundation.dart';

/// Lets a screen inside the signed-in shell switch to another bottom tab
/// by its label, e.g. the donor Home's "See all" opens the Reports tab:
///
/// ```dart
/// ShellTabs.open('Reports');
/// ```
/// RoleHome (home.dart) listens and changes the selected tab.
abstract final class ShellTabs {
  static final request = ValueNotifier<String?>(null);

  static void open(String label) {
    request.value = null; // so asking for the same tab twice still fires
    request.value = label;
  }
}
