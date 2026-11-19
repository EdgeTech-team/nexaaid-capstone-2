import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../tokens.dart';

/// The NexaAid logo (UI redesign, Nov 2026): a location pin (the barangay)
/// holding a heart (the donation), with a small arc under it (the trip in
/// between). Replaces the hand-drawn "volunteer_activism" placeholder.
class NexaAidLogo extends StatelessWidget {
  final double size;

  /// Pin, heart and arc colors. Defaults: teal pin, vest heart (on light).
  final Color? pin;
  final Color? heart;

  const NexaAidLogo({super.key, this.size = 32, this.pin, this.heart});

  /// The logo for a teal or dark background.
  const NexaAidLogo.onDark({super.key, this.size = 32})
    : pin = AppColors.harborMist,
      heart = AppColors.vest;

  static String svg(Color pin, Color heart) {
    String hex(Color c) =>
        '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">'
        '<path d="M24 3.5c-8.6 0-15.5 6.7-15.5 15.2C8.5 30 24 42 24 42'
        's15.5-12 15.5-23.3C39.5 10.2 32.6 3.5 24 3.5z" fill="${hex(pin)}"/>'
        '<path d="M24 28.5s-7-4.3-7-9.3a3.9 3.9 0 0 1 7-2.4 3.9 3.9 0 0 1 '
        '7 2.4c0 5-7 9.3-7 9.3z" fill="${hex(heart)}"/>'
        '<path d="M12 45.5c3.5-1.6 7.6-2.5 12-2.5s8.5.9 12 2.5" fill="none" '
        'stroke="${hex(pin)}" stroke-width="2.5" stroke-linecap="round" '
        'opacity="0.55"/></svg>';
  }

  @override
  Widget build(BuildContext context) {
    return SvgPicture.string(
      svg(pin ?? AppColors.harbor, heart ?? AppColors.vest),
      width: size,
      height: size,
      semanticsLabel: 'NexaAid',
    );
  }
}

/// The logo on its deep-teal rounded square, for app bars and the login
/// screen.
class NexaAidLogoTile extends StatelessWidget {
  final double size;
  const NexaAidLogoTile({super.key, this.size = 36});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.harborDeep,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: NexaAidLogo.onDark(size: size * 0.72),
    );
  }
}
