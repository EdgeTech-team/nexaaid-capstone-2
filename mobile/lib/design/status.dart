import 'package:flutter/material.dart';

/// Colors and icon for one status or priority, already adjusted for the
/// current brightness.
class ToneStyle {
  final Color base; // the fixed hue for this status
  final Color fg; // text and icon color
  final Color bg; // pill / tint background
  final IconData icon;
  const ToneStyle(this.base, this.fg, this.bg, this.icon);

  factory ToneStyle.from(Color base, IconData icon, Brightness b) {
    final dark = b == Brightness.dark;
    return ToneStyle(
      base,
      dark
          ? Color.lerp(base, Colors.white, 0.45)!
          : Color.lerp(base, Colors.black, 0.22)!,
      base.withValues(alpha: dark ? 0.24 : 0.12),
      icon,
    );
  }
}

const _slate = Color(0xFF64748B);
const _amber = Color(0xFFC77700);
const _blue = Color(0xFF1F6FD1);
const _teal = Color(0xFF0B8A7A);
const _violet = Color(0xFF6A4FD3);
const _cyan = Color(0xFF0E8FB0);
const _green = Color(0xFF2E8B3E);
const _red = Color(0xFFC0362C);

/// One fixed color per status, used everywhere a status appears
/// (chips, timelines, list accents). Do not pick status colors by hand in
/// screens; call [StatusColors.of] or use `StatusChip`.
abstract final class StatusColors {
  static const Map<String, (Color, IconData)> _map = {
    // Donation lifecycle (Item 10 timeline order)
    'pending': (_slate, Icons.schedule),
    'received': (_blue, Icons.inventory_2_outlined),
    'partly received': (_blue, Icons.timelapse),
    'confirmed': (_teal, Icons.verified_outlined),
    'in transit': (_violet, Icons.local_shipping_outlined),
    'delivered': (_cyan, Icons.where_to_vote_outlined),
    'acknowledged': (_green, Icons.task_alt),
    // Reports, accounts, requests
    'pending review': (_amber, Icons.hourglass_top),
    'validated': (_green, Icons.check_circle_outline),
    'approved': (_green, Icons.check_circle_outline),
    'active': (_green, Icons.check_circle_outline),
    'accepted': (_green, Icons.check_circle_outline),
    'scheduled': (_violet, Icons.event_available_outlined),
    'preparing': (_amber, Icons.inventory_outlined),
    'on hold': (_amber, Icons.pause_circle_outline),
    'rejected': (_red, Icons.cancel_outlined),
    'declined': (_red, Icons.cancel_outlined),
    'cancelled': (_slate, Icons.block),
    // Fulfillment
    'not started': (_slate, Icons.radio_button_unchecked),
    'partial': (_blue, Icons.timelapse),
    'in progress': (_blue, Icons.timelapse),
    'complete': (_green, Icons.task_alt),
    'fulfilled': (_green, Icons.task_alt),
  };

  /// Every status the palette knows, for the component gallery.
  static Iterable<String> get known => _map.keys;

  static ToneStyle of(String? status, Brightness b) {
    final e = _map[(status ?? '').trim().toLowerCase()];
    return ToneStyle.from(e?.$1 ?? _slate, e?.$2 ?? Icons.circle_outlined, b);
  }

  /// Base hue only (for old code that wants a single Color).
  static Color base(String? status) =>
      _map[(status ?? '').trim().toLowerCase()]?.$1 ?? _slate;
}

abstract final class PriorityColors {
  static const Map<String, (Color, IconData)> _map = {
    'critical': (Color(0xFFB3261E), Icons.priority_high),
    'high': (Color(0xFFD9480F), Icons.keyboard_double_arrow_up),
    'medium': (Color(0xFFB7791F), Icons.keyboard_arrow_up),
    'low': (_green, Icons.keyboard_arrow_down),
    'needs review': (_slate, Icons.help_outline),
    'review required': (_slate, Icons.help_outline),
  };

  static const levels = ['Critical', 'High', 'Medium', 'Low'];

  static ToneStyle of(String? p, Brightness b) {
    final e = _map[(p ?? '').trim().toLowerCase()];
    return ToneStyle.from(e?.$1 ?? _slate, e?.$2 ?? Icons.remove, b);
  }

  static Color base(String? p) =>
      _map[(p ?? '').trim().toLowerCase()]?.$1 ?? _slate;

  /// Sort key: Critical first, unknown last.
  static int rank(String? p) {
    final i = levels.indexWhere(
      (l) => l.toLowerCase() == (p ?? '').trim().toLowerCase(),
    );
    return i < 0 ? levels.length : i;
  }
}

/// Donation status timeline for donor and org dashboards (adviser item 10).
const donationLifecycle = [
  'Pending',
  'Received',
  'Confirmed',
  'In Transit',
  'Delivered',
  'Acknowledged',
];

const donationLifecycleLabels = [
  'Pledged',
  'Received by CSWS',
  'Confirmed by CMO',
  'In transit',
  'Delivered',
  'Barangay confirmed',
];
