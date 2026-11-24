import 'package:flutter/material.dart';

import 'widgets.dart';

/// The app bar's logo and title: a 32 px Harbor-teal rounded square with
/// the white hand-and-heart, "NexaAid" and the signed-in role. Shared by
/// the home screen and the pages opened from the CSWS dashboard, so the
/// logo is the same everywhere (CSWS dashboard brief, hard rule 1).
class BrandAppBarTitle extends StatelessWidget {
  const BrandAppBarTitle({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: cs.primary,
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
          child: Icon(Icons.volunteer_activism, size: 18, color: cs.onPrimary),
        ),
        Gaps.h12,
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('NexaAid', style: t.titleMedium),
              Text(
                api.loggedIn ? (api.role ?? 'Signed in') : 'Guest',
                overflow: TextOverflow.ellipsis,
                style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
