import 'package:flutter/material.dart';

import '../../design/design.dart';

/// Photo beside the impact numbers, e.g. 'assets/images/impact.jpg'.
/// Leave empty for no photo. Use your own photos (or ones you have
/// permission for), and get consent before showing identifiable people.
const kImpactImage = 'assets/images/exampleimg.jpg';

// ---------------------------------------------------------------------------
// 4. Credentials: only what is true
// ---------------------------------------------------------------------------

/// Fill these in. Leave a value empty to hide that line.
/// Only list an office if it actually gave input to the project.
const _university =
    'Cebu Technological University Main Campus, College of Computer, '
    'Information and Communications Technology';
const _program = 'BS Information Systems capstone project, 2026';
const _adviser = ''; // e.g. 'Adviser: Dr. Juan Dela Cruz'
const _consultedOffices = <String>[]; // e.g. ['CSWS Mandaue']

class CredentialsCard extends StatelessWidget {
  const CredentialsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final rows = <(IconData, String)>[
      (Icons.school_outlined, _university),
      (Icons.workspace_premium_outlined, _program),
      if (_adviser.isNotEmpty) (Icons.person_outline, _adviser),
      if (_consultedOffices.isNotEmpty)
        (
          Icons.apartment_outlined,
          'Consulted with: ${_consultedOffices.join(', ')}',
        ),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: Space.sm),
      child: AppCard(
        child: Column(
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) Gaps.v12,
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(rows[i].$1, size: 20, color: cs.onSurfaceVariant),
                  Gaps.h12,
                  Expanded(
                    child: Text(
                      rows[i].$2,
                      style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
