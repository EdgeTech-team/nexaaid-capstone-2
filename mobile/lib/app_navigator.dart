import 'package:flutter/widgets.dart';

/// The app's one navigator (NexaAidApp's MaterialApp). Services outside the
/// widget tree use it to open a screen, e.g. push.dart when a push
/// notification is tapped.
final appNavigator = GlobalKey<NavigatorState>();
