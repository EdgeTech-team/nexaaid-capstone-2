import 'package:flutter/material.dart';

import '../status.dart';
import '../tokens.dart';
import 'motion.dart';

/// Card with the standard padding. Pass [onTap] to make it tappable.
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final VoidCallback? onTap;
  final Color? color;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Space.md),
    this.margin = EdgeInsets.zero,
    this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final inner = Padding(padding: padding, child: child);
    return Card(
      margin: margin,
      color: color,
      child: onTap == null ? inner : InkWell(onTap: onTap, child: inner),
    );
  }
}

/// Section title with an optional action on the right ("See all").
class SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? action;
  const SectionHeader(this.title, {super.key, this.subtitle, this.action});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: Space.lg, bottom: Space.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(title, style: t.titleLarge),
                ),
                if (subtitle != null) ...[
                  Gaps.v4,
                  Text(
                    subtitle!,
                    style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

/// Number + label card for dashboards.
class StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color? color;
  final String? note;

  const StatCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.color,
    this.note,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final c = color ?? cs.primary;
    final iconFg = dark ? Color.lerp(c, Colors.white, 0.35)! : c;
    return Semantics(
      label: '$label: $value${note == null ? '' : ', $note'}',
      excludeSemantics: true,
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: c.withValues(alpha: dark ? 0.24 : 0.12),
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Icon(icon, size: 20, color: iconFg),
            ),
            Gaps.v12,
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: CountUpText(value, style: t.headlineMedium),
            ),
            Gaps.v4,
            Text(
              label,
              style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (note != null)
              Text(
                note!,
                style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}

/// Lays stat cards out 2 per row on phones, 3 on large phones, 4 on tablets.
class StatCardGrid extends StatelessWidget {
  final List<Widget> cards;
  const StatCardGrid(this.cards, {super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final cols = c.maxWidth >= 900
            ? 4
            : c.maxWidth >= Breakpoints.medium
            ? 3
            : 2;
        final w = (c.maxWidth - Space.sm * (cols - 1)) / cols;
        return Wrap(
          spacing: Space.sm,
          runSpacing: Space.sm,
          children: [for (final x in cards) SizedBox(width: w, child: x)],
        );
      },
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final ToneStyle tone;
  final bool showIcon;
  final String kind;
  const _Pill(this.text, this.tone, this.showIcon, this.kind);

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium
        ?.copyWith(color: tone.fg, fontWeight: FontWeight.w700);
    return Semantics(
      label: '$kind: $text',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: tone.bg,
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showIcon) ...[
              Icon(tone.icon, size: 14, color: tone.fg),
              Gaps.h4,
            ],
            Flexible(
              child: Text(
                text,
                style: style,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Status pill with the fixed color for that status.
class StatusChip extends StatelessWidget {
  final String? status;
  final String? label; // optional friendlier text, same color
  final bool showIcon;
  const StatusChip(this.status, {super.key, this.label, this.showIcon = true});

  @override
  Widget build(BuildContext context) => _Pill(
    label ?? status ?? 'Unknown',
    StatusColors.of(status, Theme.of(context).brightness),
    showIcon,
    'Status',
  );
}

/// Priority pill (Critical, High, Medium, Low).
class PriorityChip extends StatelessWidget {
  final String? priority;
  final bool showIcon;
  const PriorityChip(this.priority, {super.key, this.showIcon = true});

  @override
  Widget build(BuildContext context) => _Pill(
    priority ?? 'No priority',
    PriorityColors.of(priority, Theme.of(context).brightness),
    showIcon,
    'Priority',
  );
}

/// Fulfillment progress of a report: percent, bar, "x of y delivered".
class FulfillmentBar extends StatelessWidget {
  final num delivered;
  final num needed;
  final num? percent;
  final String label;

  const FulfillmentBar({
    super.key,
    required this.delivered,
    required this.needed,
    this.percent,
    this.label = 'Fulfilled',
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final pct = (percent ?? (needed > 0 ? delivered * 100 / needed : 0))
        .toDouble()
        .clamp(0, 100)
        .toDouble();
    final done = pct >= 100;
    final muted = t.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    return Semantics(
      label:
          '$label ${pct.toStringAsFixed(0)} percent, '
          '$delivered of $needed items delivered',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: muted)),
              Text('${pct.toStringAsFixed(0)}%', style: t.labelLarge),
            ],
          ),
          Gaps.v4,
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.pill),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: pct / 100),
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 800),
              curve: Motion.curve,
              builder: (context, v, _) => LinearProgressIndicator(
                value: v,
                minHeight: 8,
                color: done ? AppColors.success : cs.primary,
                backgroundColor: cs.surfaceContainerHighest,
              ),
            ),
          ),
          Gaps.v4,
          Text('$delivered of $needed items delivered', style: muted),
        ],
      ),
    );
  }
}

/// Step-by-step status, e.g. the donation lifecycle on dashboards.
///
/// ```dart
/// StatusTimeline(
///   steps: donationLifecycle,
///   labels: donationLifecycleLabels,
///   current: donation['status'],
/// )
/// ```
/// Use `axis: Axis.vertical` with [dates] for a detail screen.
class StatusTimeline extends StatelessWidget {
  final List<String> steps;
  final List<String>? labels;
  final String? current;
  final Axis axis;
  final Map<String, String>? dates; // step -> already formatted date

  const StatusTimeline({
    super.key,
    required this.steps,
    required this.current,
    this.labels,
    this.axis = Axis.horizontal,
    this.dates,
  });

  int get _at => steps.indexWhere(
    (s) => s.toLowerCase() == (current ?? '').trim().toLowerCase(),
  );

  String _label(int i) =>
      labels != null && i < labels!.length ? labels![i] : steps[i];

  @override
  Widget build(BuildContext context) {
    final at = _at;
    final summary = at < 0
        ? 'Status: ${current ?? 'unknown'}'
        : 'Status: ${_label(at)}, step ${at + 1} of ${steps.length}';
    return Semantics(
      label: summary,
      excludeSemantics: true,
      child: axis == Axis.horizontal
          ? _horizontal(context, at)
          : _vertical(context, at),
    );
  }

  Widget _horizontal(BuildContext context, int at) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final n = steps.length;
    Widget line(bool on) => Expanded(
      child: Container(height: 2, color: on ? cs.primary : cs.outlineVariant),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < n; i++)
          Expanded(
            child: Column(
              children: [
                SizedBox(
                  height: 22,
                  child: Row(
                    children: [
                      i == 0 ? const Spacer() : line(i <= at),
                      _Dot(done: i < at, current: i == at),
                      i == n - 1 ? const Spacer() : line(i < at),
                    ],
                  ),
                ),
                Gaps.v4,
                Text(
                  _label(i),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: t.labelSmall?.copyWith(
                    color: i <= at ? cs.onSurface : cs.onSurfaceVariant,
                    fontWeight: i == at ? FontWeight.w800 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _vertical(BuildContext context, int at) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final n = steps.length;
    return Column(
      children: [
        for (var i = 0; i < n; i++)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 24,
                  child: Column(
                    children: [
                      _Dot(done: i < at, current: i == at),
                      if (i < n - 1)
                        Expanded(
                          child: Container(
                            width: 2,
                            color: i < at ? cs.primary : cs.outlineVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                Gaps.h12,
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: Space.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _label(i),
                          style: t.bodyLarge?.copyWith(
                            color: i <= at ? cs.onSurface : cs.onSurfaceVariant,
                            fontWeight: i == at
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                        if (dates?[steps[i]] != null)
                          Text(
                            dates![steps[i]]!,
                            style: t.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  final bool done;
  final bool current;
  const _Dot({required this.done, required this.current});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (done) {
      return Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle),
        child: Icon(Icons.check, size: 14, color: cs.onPrimary),
      );
    }
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: current ? cs.primaryContainer : cs.surface,
        border: Border.all(
          color: current ? cs.primary : cs.outlineVariant,
          width: 2,
        ),
      ),
      child: current
          ? Center(
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: cs.primary,
                  shape: BoxShape.circle,
                ),
              ),
            )
          : null,
    );
  }
}
