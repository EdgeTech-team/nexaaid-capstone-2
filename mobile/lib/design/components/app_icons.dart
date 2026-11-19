import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../tokens.dart';

/// NexaAid icon set (UI redesign, Nov 2026): one duotone line style for the
/// whole app. 24px grid, 1.75 stroke, rounded ends, the main shape filled at
/// 20% of the icon color. Drawn from SVG so every screen gets the same look.
///
/// Usage: `AppIcon('qrscan', color: cs.primary)` or `IconTile('box')`.
/// The names match the canvas "Brand · Icon set" artboard.
class AppIcon extends StatelessWidget {
  final String name;
  final double size;
  final Color? color;

  /// Read by screen readers. Leave null for decorative icons (most icons sit
  /// next to a text label, which already says what they mean).
  final String? semanticLabel;

  const AppIcon(
    this.name, {
    super.key,
    this.size = 24,
    this.color,
    this.semanticLabel,
  });

  /// True when [name] is in the set.
  static bool has(String name) => _paths.containsKey(name);

  static String svg(String name) =>
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" '
      'stroke="currentColor" stroke-width="1.75" stroke-linecap="round" '
      'stroke-linejoin="round">${_paths[name] ?? _paths['box']!}</svg>';

  @override
  Widget build(BuildContext context) {
    final c = color ?? IconTheme.of(context).color ?? AppColors.ink;
    final picture = SvgPicture.string(
      svg(name),
      width: size,
      height: size,
      theme: SvgTheme(currentColor: c),
      excludeFromSemantics: semanticLabel == null,
      semanticsLabel: semanticLabel,
    );
    return SizedBox(width: size, height: size, child: picture);
  }
}

/// An [AppIcon] on a soft tinted square, as on every card and list row of the
/// redesign. [tint] picks the color pair (see [AppTints]).
class IconTile extends StatelessWidget {
  final String name;
  final Tint tint;
  final double size;

  const IconTile(
    this.name, {
    super.key,
    this.tint = AppTints.teal,
    this.size = 40,
  });

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: tint.bgFor(b),
          // Smaller than the card around it (16): inner shapes get less radius.
          borderRadius: BorderRadius.circular(size >= 40 ? Radii.md : Radii.sm),
        ),
        child: AppIcon(name, size: size * 0.55, color: tint.fgFor(b)),
      ),
    );
  }
}

/// The icon for a bottom-menu tab, by its label (labels as in home.dart).
/// Null for a label the set does not know: the tab keeps its Material icon.
String? appIconForTab(String label) => _tabIcons[label];

const Map<String, String> _tabIcons = {
  'Dashboard': 'dashboard',
  'Overview': 'dashboard',
  'Reports': 'article',
  'My giving': 'giving',
  'Profile': 'person',
  'Validate': 'validate',
  'Encode SMS': 'sms',
  'Monitoring': 'monitor',
  'Records': 'folder',
  'Accounts': 'accounts',
  'Logistics': 'firetruck',
  'Deliveries': 'truck',
  'New report': 'editnote',
  'SMS report': 'sms',
  'Receive': 'qrscan',
  'Pickups': 'door',
  'Acknowledge': 'verified',
  'History': 'history',
  'Incoming aid': 'inbox',
  'Donation info': 'wallet',
};

const Map<String, String> _paths = {
  'accounts': '<circle cx="9" cy="8" r="3.5" fill="currentColor" fill-opacity="0.2"/><path d="M3 20a6 6 0 0 1 9.5-4.9"/><circle cx="17.5" cy="17.5" r="2.5"/><path d="M17.5 13.5v1.5M17.5 20v1.5M13.5 17.5H15M20 17.5h1.5"/>',
  'arrowleft': '<path d="M19 12H5M11 6l-6 6 6 6"/>',
  'article': '<rect x="4" y="3" width="16" height="18" rx="2.5" fill="currentColor" fill-opacity="0.2"/><path d="M8 8h8M8 12h8M8 16h5"/>',
  'back': '<path d="M9 14L4 9l5-5"/><path d="M4 9h10a6 6 0 0 1 0 12h-3"/>',
  'bell': '<path d="M6 16v-5a6 6 0 0 1 12 0v5l1.5 2h-15z" fill="currentColor" fill-opacity="0.2"/><path d="M10 21h4"/>',
  'box': '<path d="M3 7.5L12 3l9 4.5v9L12 21l-9-4.5z" fill="currentColor" fill-opacity="0.2"/><path d="M3 7.5l9 4.5 9-4.5M12 12v9"/>',
  'building': '<path d="M4 21V5a2 2 0 0 1 2-2h7a2 2 0 0 1 2 2v16z" fill="currentColor" fill-opacity="0.2"/><path d="M15 10h3a2 2 0 0 1 2 2v9M2 21h20M8 7h3M8 11h3M8 15h3"/>',
  'calendar': '<rect x="3" y="5" width="18" height="16" rx="2.5" fill="currentColor" fill-opacity="0.2"/><path d="M3 10h18M8 3v4M16 3v4"/>',
  'chart': '<rect x="4" y="12" width="4" height="8" rx="1" fill="currentColor" fill-opacity="0.2"/><rect x="10" y="7" width="4" height="13" rx="1" fill="currentColor" fill-opacity="0.2"/><rect x="16" y="3" width="4" height="17" rx="1" fill="currentColor" fill-opacity="0.2"/>',
  'check': '<circle cx="12" cy="12" r="9" fill="currentColor" fill-opacity="0.2"/><path d="M8 12l3 3 5-6"/>',
  'chevron': '<path d="M9 6l6 6-6 6"/>',
  'cloudoff': '<path d="M7 18h10a4 4 0 0 0 .8-7.9A6 6 0 0 0 6.3 9 4.5 4.5 0 0 0 7 18z" fill="currentColor" fill-opacity="0.2"/><path d="M4 4l16 16"/>',
  'dashboard': '<rect x="3" y="3" width="8" height="10" rx="2" fill="currentColor" fill-opacity="0.2"/><rect x="13" y="3" width="8" height="6" rx="2"/><rect x="13" y="11" width="8" height="10" rx="2" fill="currentColor" fill-opacity="0.2"/><rect x="3" y="15" width="8" height="6" rx="2"/>',
  'doneall': '<circle cx="12" cy="12" r="9" fill="currentColor" fill-opacity="0.2"/><path d="M5 12.5l3 3 6-7M11 15.5l1 0 6-7"/>',
  'door': '<path d="M6 21V4.5A1.5 1.5 0 0 1 7.5 3h9A1.5 1.5 0 0 1 18 4.5V21" fill="currentColor" fill-opacity="0.2"/><path d="M3 21h18M14.5 12.5h.01"/>',
  'edit': '<path d="M4 20h4L19 9l-4-4L4 16z" fill="currentColor" fill-opacity="0.2"/><path d="M13.5 6.5l4 4"/>',
  'editnote': '<path d="M5 3h10l4 4v6" fill="currentColor" fill-opacity="0.2"/><path d="M5 3v18h6M9 8h5M9 12h4"/><path d="M14 21l.5-2.5 5-5 2 2-5 5z"/>',
  'event': '<rect x="3" y="5" width="18" height="16" rx="2.5" fill="currentColor" fill-opacity="0.2"/><path d="M3 10h18M8 3v4M16 3v4M9 15.5l2 2 4-4"/>',
  'eye': '<path d="M2.5 12S6 5 12 5s9.5 7 9.5 7-3.5 7-9.5 7-9.5-7-9.5-7z" fill="currentColor" fill-opacity="0.2"/><circle cx="12" cy="12" r="3"/>',
  'filter': '<path d="M3 5h18l-7 8.5V19l-4 2v-7.5z" fill="currentColor" fill-opacity="0.2"/>',
  'firetruck': '<path d="M2 6h11v10H2z" fill="currentColor" fill-opacity="0.2"/><path d="M13 9h4l4 4v3h-8zM5 3h5"/><circle cx="6" cy="18" r="2"/><circle cx="17" cy="18" r="2"/>',
  'flood': '<path d="M12 3s-6 7-6 11a6 6 0 0 0 12 0c0-4-6-11-6-11z" fill="currentColor" fill-opacity="0.2"/><path d="M9 15a3 3 0 0 0 3 3"/>',
  'folder': '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" fill="currentColor" fill-opacity="0.2"/><path d="M3 10h18"/>',
  'giving': '<path d="M12 12.5s-4-2.5-4-5.6A2.3 2.3 0 0 1 12 5.5a2.3 2.3 0 0 1 4 1.4c0 3.1-4 5.6-4 5.6z" fill="currentColor" fill-opacity="0.2"/><path d="M3 15h3.5l4 1.5h2.5a1.5 1.5 0 0 1 0 3H9.5"/><path d="M3 20.5h3.5l5 1 8-4a1.6 1.6 0 0 0-1.5-2.8L13.5 16.5"/>',
  'history': '<circle cx="12" cy="12" r="8.5" fill="currentColor" fill-opacity="0.2"/><path d="M12 7.5V12l3 2"/>',
  'hourglass': '<path d="M7 3h10v3a5 5 0 0 1-5 6 5 5 0 0 1 5 6v3H7v-3a5 5 0 0 1 5-6 5 5 0 0 1-5-6z" fill="currentColor" fill-opacity="0.2"/>',
  'hygiene': '<rect x="7" y="9" width="10" height="12" rx="2.5" fill="currentColor" fill-opacity="0.2"/><path d="M10 9V6h4v3M14 4h3"/>',
  'inbox': '<path d="M3 13l2.5-7.5A2 2 0 0 1 7.4 4h9.2a2 2 0 0 1 1.9 1.5L21 13v5a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" fill="currentColor" fill-opacity="0.2"/><path d="M3 13h5l1.5 3h5L16 13h5"/>',
  'info': '<circle cx="12" cy="12" r="9" fill="currentColor" fill-opacity="0.2"/><path d="M12 11v6M12 7.5h.01"/>',
  'layers': '<path d="M12 3l9 4.5-9 4.5-9-4.5z" fill="currentColor" fill-opacity="0.2"/><path d="M3 12l9 4.5 9-4.5M3 16.5L12 21l9-4.5"/>',
  'lock': '<rect x="4" y="10" width="16" height="11" rx="2.5" fill="currentColor" fill-opacity="0.2"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/>',
  'logout': '<path d="M14 4h4a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-4M10 16l-4-4 4-4M6 12h10"/>',
  'mail': '<rect x="3" y="5" width="18" height="14" rx="2.5" fill="currentColor" fill-opacity="0.2"/><path d="M3 7.5l9 6 9-6"/>',
  'medkit': '<rect x="3" y="7" width="18" height="13" rx="2.5" fill="currentColor" fill-opacity="0.2"/><path d="M9 7V5a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2M12 10.5v6M9 13.5h6"/>',
  'monitor': '<rect x="3" y="4" width="18" height="14" rx="2.5" fill="currentColor" fill-opacity="0.2"/><path d="M6 11h3l1.5-3 3 6 1.5-3h3"/><path d="M9 21h6"/>',
  'navigate': '<path d="M3 11l18-8-8 18-2-8z" fill="currentColor" fill-opacity="0.2"/>',
  'pause': '<circle cx="12" cy="12" r="9" fill="currentColor" fill-opacity="0.2"/><path d="M10 9v6M14 9v6"/>',
  'person': '<circle cx="12" cy="8" r="4" fill="currentColor" fill-opacity="0.2"/><path d="M4 21a8 8 0 0 1 16 0"/>',
  'phone': '<path d="M5 4h4l2 5-2.5 1.5a11 11 0 0 0 5 5L15 13l5 2v4a2 2 0 0 1-2 2A16 16 0 0 1 3 6a2 2 0 0 1 2-2z" fill="currentColor" fill-opacity="0.2"/>',
  'pin': '<path d="M12 21s-7-6.2-7-11.5a7 7 0 0 1 14 0C19 14.8 12 21 12 21z" fill="currentColor" fill-opacity="0.2"/><circle cx="12" cy="9.5" r="2.5"/>',
  'pincheck': '<path d="M12 21s-7-6.2-7-11.5a7 7 0 0 1 14 0C19 14.8 12 21 12 21z" fill="currentColor" fill-opacity="0.2"/><path d="M9 9.5l2 2 4-4"/>',
  'plus': '<path d="M12 5v14M5 12h14"/>',
  'qr': '<rect x="3" y="3" width="7" height="7" rx="1.5" fill="currentColor" fill-opacity="0.2"/><rect x="14" y="3" width="7" height="7" rx="1.5" fill="currentColor" fill-opacity="0.2"/><rect x="3" y="14" width="7" height="7" rx="1.5" fill="currentColor" fill-opacity="0.2"/><path d="M14 14h3v3h-3zM20 14v.01M20 20h-3M17 20v.01"/>',
  'qrscan': '<path d="M4 8V6a2 2 0 0 1 2-2h2M16 4h2a2 2 0 0 1 2 2v2M20 16v2a2 2 0 0 1-2 2h-2M8 20H6a2 2 0 0 1-2-2v-2"/><rect x="8" y="8" width="8" height="8" rx="1.5" fill="currentColor" fill-opacity="0.2"/><path d="M4 12h16"/>',
  'refresh': '<path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 5v6h-6"/>',
  'rice': '<path d="M4 11h16a8 8 0 0 1-16 0z" fill="currentColor" fill-opacity="0.2"/><path d="M8 11c0-3 1.5-5 4-6 2.5 1 4 3 4 6M10 8l1 1M14 7.5l-1 1.5"/>',
  'route': '<circle cx="6" cy="18" r="2.5" fill="currentColor" fill-opacity="0.2"/><circle cx="18" cy="6" r="2.5" fill="currentColor" fill-opacity="0.2"/><path d="M8.5 18H16a3 3 0 0 0 0-6H8a3 3 0 0 1 0-6h7.5"/>',
  'search': '<circle cx="11" cy="11" r="6.5" fill="currentColor" fill-opacity="0.2"/><path d="M16 16l4.5 4.5"/>',
  'settings': '<circle cx="12" cy="12" r="3" fill="currentColor" fill-opacity="0.2"/><path d="M12 2.5v2.5M12 19v2.5M4.6 4.6l1.8 1.8M17.6 17.6l1.8 1.8M2.5 12H5M19 12h2.5M4.6 19.4l1.8-1.8M17.6 6.4l1.8-1.8"/>',
  'shield': '<path d="M12 3l8 3v6c0 4.5-3.4 8-8 9-4.6-1-8-4.5-8-9V6z" fill="currentColor" fill-opacity="0.2"/><path d="M8.5 12l2.5 2.5 4.5-5"/>',
  'shirt': '<path d="M8 3l-5 3 2 4 2-1v12h10V9l2 1 2-4-5-3a4 4 0 0 1-8 0z" fill="currentColor" fill-opacity="0.2"/>',
  'sms': '<path d="M4 5h16v11H9l-5 4z" fill="currentColor" fill-opacity="0.2"/><path d="M9 10.5l2 2 4-4"/>',
  'sort': '<path d="M7 4v16M3.5 16.5L7 20l3.5-3.5M17 20V4M13.5 7.5L17 4l3.5 3.5"/>',
  'star': '<path d="M12 3l2.7 5.6 6.1.8-4.5 4.2 1.1 6-5.4-3-5.4 3 1.1-6L3.2 9.4l6.1-.8z" fill="currentColor" fill-opacity="0.2"/>',
  'timer': '<circle cx="12" cy="13" r="8" fill="currentColor" fill-opacity="0.2"/><path d="M12 9v4l2.5 1.5M9 2.5h6"/>',
  'today': '<rect x="3" y="5" width="18" height="16" rx="2.5" fill="currentColor" fill-opacity="0.2"/><path d="M3 10h18M8 3v4M16 3v4"/><rect x="7" y="13" width="4" height="4" rx="1"/>',
  'truck': '<path d="M2 6h11v10H2z" fill="currentColor" fill-opacity="0.2"/><path d="M13 9h4l4 4v3h-8z"/><circle cx="6" cy="18" r="2"/><circle cx="17" cy="18" r="2"/>',
  'users': '<circle cx="9" cy="8" r="3.5" fill="currentColor" fill-opacity="0.2"/><path d="M2.5 20a6.5 6.5 0 0 1 13 0"/><path d="M16 4.5a3.5 3.5 0 0 1 0 7M18 14a5.5 5.5 0 0 1 3.5 6"/>',
  'validate': '<rect x="4" y="3" width="16" height="18" rx="2.5" fill="currentColor" fill-opacity="0.2"/><path d="M8 12l2.5 2.5L16 9"/>',
  'verified': '<path d="M12 2.5l2.5 2 3.2-.3.7 3.1 2.6 1.9-1.2 3 1.2 3-2.6 1.9-.7 3.1-3.2-.3-2.5 2-2.5-2-3.2.3-.7-3.1L3.1 15l1.2-3-1.2-3 2.6-1.9.7-3.1 3.2.3z" fill="currentColor" fill-opacity="0.2"/><path d="M8.5 12l2.5 2.5 4.5-5"/>',
  'wallet': '<rect x="3" y="6" width="18" height="14" rx="2.5" fill="currentColor" fill-opacity="0.2"/><path d="M3 10h18M16 14.5h2M6 6l9-3 1.5 3"/>',
  'warning': '<path d="M12 3.5l9.5 17h-19z" fill="currentColor" fill-opacity="0.2"/><path d="M12 10v4.5M12 17.5h.01"/>',
  'water': '<path d="M9 3h6v3l1.5 2v12a1 1 0 0 1-1 1h-7a1 1 0 0 1-1-1V8L9 6z" fill="currentColor" fill-opacity="0.2"/><path d="M9 6h6M7.5 12h9"/>',
  'x': '<path d="M6 6l12 12M18 6L6 18"/>',
};
