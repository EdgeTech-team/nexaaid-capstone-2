import 'package:flutter/material.dart';

import '../tokens.dart';

/// UI redesign (Nov 2026) building blocks, matching the "NexaAid redesign"
/// canvas: a teal hero with the most urgent card overlapping it, number
/// tiles in groups, action rows with count pills. Material icons only.

/// A Material icon on a soft tinted square (40px in rows, 32px in tiles).
class TintIcon extends StatelessWidget {
  final IconData icon;
  final Tint tint;
  final double size;
  const TintIcon(this.icon, {super.key, this.tint = AppTints.teal, this.size = 40});

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
          // Smaller than the 16px card corner around it.
          borderRadius: BorderRadius.circular(size >= 40 ? Radii.md : 10),
        ),
        child: Icon(icon, size: size * 0.55, color: tint.fgFor(b)),
      ),
    );
  }
}

/// A small rounded count, tinted by meaning (amber = waiting, red = late).
class CountPill extends StatelessWidget {
  final String text;
  final Tint tint;
  const CountPill(this.text, {super.key, this.tint = AppTints.amber});

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Container(
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      padding: const EdgeInsets.symmetric(horizontal: Space.xs),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tint.bgFor(b),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: tint.fgFor(b),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// The teal top of a role's main tab: title, subtitle, and an optional card
/// that overlaps the teal by 36px (the most urgent thing on the screen).
class HeroHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? overlap;

  /// Inside a list that already has side padding, the teal still reaches the
  /// screen edges: pass that padding here (e.g. 16).
  final double bleed;

  /// The same above it, for a list with top padding: the teal reaches the
  /// top of the screen and the title keeps its place.
  final double bleedTop;

  /// Beside the title (e.g. the light / dark switch on Settings).
  final Widget? trailing;
  const HeroHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.overlap,
    this.bleed = 0,
    this.bleedTop = 0,
    this.trailing,
  });

  static const _overlap = 36.0;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    // The teal may paint past the side padding of the list it sits in
    // ([bleed]); the title, subtitle and card stay where they are.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Teal behind everything except the last 36px of the card.
        Positioned(
          left: -bleed,
          right: -bleed,
          top: -bleedTop,
          bottom: 0,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // SizedBox.expand: an empty ColoredBox alone has no width.
              const Expanded(
                child: SizedBox.expand(
                  child: ColoredBox(color: AppColors.harbor),
                ),
              ),
              SizedBox(height: overlap == null ? 0 : _overlap),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            bleed > 0 ? 0 : Space.md,
            bleedTop >= Space.md ? 0 : Space.md - bleedTop,
            bleed > 0 ? 0 : Space.md,
            overlap == null ? Space.lg : 0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        title,
                        style: t.headlineSmall?.copyWith(
                          color: AppColors.onDark,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  ?trailing,
                ],
              ),
              if (subtitle != null) ...[
                Gaps.v4,
                Text(
                  subtitle!,
                  style: t.bodyMedium?.copyWith(color: AppColors.harborMist),
                ),
              ],
              if (overlap != null) ...[
                const SizedBox(height: Space.md + 4),
                overlap!,
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// A white card with a title row and its rows, used for "Needs your action".
class ActionCard extends StatelessWidget {
  final String title;
  final String? count;
  final List<Widget> rows;
  const ActionCard({super.key, required this.title, this.count, required this.rows});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 3,
      shadowColor: Colors.black26,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.md, Space.sm + 2, Space.xs, Space.xxs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: Space.xs),
              child: Row(
                children: [
                  Expanded(child: Text(title, style: t.titleMedium)),
                  if (count != null) CountPill(count!),
                ],
              ),
            ),
            ...rows,
          ],
        ),
      ),
    );
  }
}

/// One tappable line in an [ActionCard]: tinted icon, label, an optional
/// line of help under it, count, chevron.
class ActionRow extends StatelessWidget {
  final IconData icon;
  final Tint tint;
  final String label;
  final String? note;
  final String? count;
  final VoidCallback? onTap;
  const ActionRow({
    super.key,
    required this.icon,
    required this.label,
    this.tint = AppTints.amber,
    this.note,
    this.count,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final said = [
      count == null ? label : '$label: $count',
      ?note,
    ].join(', ');
    return Semantics(
      button: onTap != null,
      label: said,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.md),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.xs),
            child: Row(
              children: [
                TintIcon(icon, tint: tint),
                Gaps.h12,
                Expanded(
                  child: note == null
                      ? Text(label, style: t.titleSmall)
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(label, style: t.titleSmall),
                            Text(
                              note!,
                              style: t.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                ),
                if (count != null) ...[Gaps.h8, CountPill(count!, tint: tint)],
                if (onTap != null)
                  Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A number tile: small uppercase group caption, tinted icon, big number,
/// label, optional note. A chevron only when it can be tapped.
class NumberTile extends StatelessWidget {
  final IconData icon;
  final Tint tint;
  final String value;
  final String label;
  final String? note;
  final String? caption;
  final VoidCallback? onTap;
  final bool selected;
  const NumberTile({
    super.key,
    required this.icon,
    required this.value,
    required this.label,
    this.tint = AppTints.teal,
    this.note,
    this.caption,
    this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final muted = t.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    return Semantics(
      button: onTap != null,
      selected: selected,
      label: '$label: $value${note == null ? '' : ', $note'}',
      excludeSemantics: true,
      child: Card(
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.lg),
          side: selected ? BorderSide(color: cs.primary, width: 2) : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(Space.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (caption != null) ...[
                  Text(
                    caption!.toUpperCase(),
                    style: t.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                      letterSpacing: 0.8,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Gaps.v8,
                ],
                Row(
                  children: [
                    TintIcon(icon, tint: tint, size: 32),
                    const Spacer(),
                    if (onTap != null)
                      Icon(Icons.chevron_right, size: 18, color: cs.onSurfaceVariant),
                  ],
                ),
                Gaps.v8,
                Text(value, style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                Text(label, style: muted),
                if (note != null) Text(note!, style: muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Number tiles in a grid: 3 across, 2 on a narrow phone or with large text.
class NumberGrid extends StatelessWidget {
  final List<Widget> tiles;
  const NumberGrid(this.tiles, {super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final scale = MediaQuery.textScalerOf(context).scale(1);
        final cols = c.maxWidth < 360 || scale > 1.3 ? 2 : 3;
        const gap = Space.xs + 2;
        final w = (c.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final tile in tiles) SizedBox(width: w, child: tile)],
        );
      },
    );
  }
}

/// One step of a [SteppedForm]: a short title and the fields it holds.
class FormStep {
  final String title;
  final List<Widget> children;

  /// Extra check for Next, for inputs that are not form fields (e.g. a
  /// date picker). Returns false to stay on the step.
  final bool Function()? check;
  const FormStep(this.title, this.children, {this.check});
}

/// UI redesign: a long form shown one step at a time, with a progress bar
/// ("Step 2 of 3", the step's title, a bar and the step names), Back and
/// Next. Every step stays built and only the current one shows, so the
/// [Form] around it still validates, saves and resets every field, as
/// before. Next checks the fields of the current step only; the step names
/// open any step. The last step shows [submit], which is given
/// `showFirstError`: call it right after your submit validated the form, and
/// the first step with a field in red opens.
class SteppedForm extends StatefulWidget {
  /// Above the progress bar (e.g. the page title and a note).
  final List<Widget> header;
  final List<FormStep> steps;
  /// Null when the screen has its own submit button (e.g. a sticky bar):
  /// the last step then only shows Back. Use a GlobalKey to the
  /// [SteppedFormState] to call [SteppedFormState.showFirstError].
  final Widget Function(BuildContext context, VoidCallback showFirstError)?
  submit;
  final EdgeInsetsGeometry padding;

  /// False inside a bottom sheet or a dialog that scrolls by itself.
  final bool scrolls;
  const SteppedForm({
    super.key,
    this.header = const [],
    required this.steps,
    this.submit,
    this.padding = const EdgeInsets.all(Space.md),
    this.scrolls = true,
  });

  @override
  State<SteppedForm> createState() => SteppedFormState();
}

class SteppedFormState extends State<SteppedForm> {
  int _at = 0;
  final _top = GlobalKey();
  final List<GlobalKey> _keys = [];

  /// The step showing (0 = first).
  int get step => _at.clamp(0, widget.steps.length - 1);

  /// Opens step [i], e.g. 0 after the form was sent and cleared.
  void goTo(int i) {
    if (!mounted) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _at = i.clamp(0, widget.steps.length - 1));
    // Back to the progress bar, so the new step is read from its top.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _top.currentContext;
      if (c != null && c.mounted && Scrollable.maybeOf(c) != null) {
        Scrollable.ensureVisible(
          c,
          duration: MediaQuery.disableAnimationsOf(c)
              ? Duration.zero
              : Motion.normal,
          curve: Motion.curve,
        );
      }
    });
  }

  /// The form fields inside step [i] (built, even when hidden).
  List<FormFieldState<Object?>> _fields(int i) {
    final out = <FormFieldState<Object?>>[];
    final root = i < _keys.length ? _keys[i].currentContext : null;
    if (root == null) return out;
    void visit(Element e) {
      if (e is StatefulElement && e.state is FormFieldState) {
        out.add(e.state as FormFieldState<Object?>);
      }
      e.visitChildren(visit);
    }

    root.visitChildElements(visit);
    return out;
  }

  void _next() {
    // validate() on each field (not just the first) so all show in red.
    var ok = true;
    for (final f in _fields(step)) {
      ok = f.validate() && ok;
    }
    final check = widget.steps[step].check;
    if (check != null) ok = check() && ok;
    if (ok) goTo(step + 1);
  }

  /// After the whole form was validated: open the first step in red.
  void showFirstError() {
    for (var i = 0; i < widget.steps.length; i++) {
      if (_fields(i).any((f) => f.hasError)) {
        if (i != step) goTo(i);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final steps = widget.steps;
    while (_keys.length < steps.length) {
      _keys.add(GlobalKey());
    }
    final at = step;
    final last = at == steps.length - 1;
    final single = steps.length == 1;
    final submit = widget.submit;
    final body = Padding(
      padding: widget.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...widget.header,
          // One step: no progress bar, just the fields.
          KeyedSubtree(
            key: _top,
            child: single
                ? const SizedBox.shrink()
                : StepProgress(
                    step: at,
                    titles: [for (final s in steps) s.title],
                    onOpen: goTo,
                  ),
          ),
          if (!single) Gaps.v16,
          for (var i = 0; i < steps.length; i++)
            Offstage(
              offstage: i != at,
              child: TickerMode(
                enabled: i == at,
                child: ExcludeFocus(
                  excluding: i != at,
                  child: KeyedSubtree(
                    key: _keys[i],
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: steps[i].children,
                    ),
                  ),
                ),
              ),
            ),
          if (!(last && submit == null && at == 0)) Gaps.v24,
          if (!(last && submit == null && at == 0))
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (at > 0) ...[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => goTo(at - 1),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                    ),
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('Back'),
                  ),
                ),
                if (!last || submit != null) Gaps.h12,
              ],
              if (last && submit == null)
                const Spacer(flex: 2)
              else
              Expanded(
                flex: 2,
                child: last
                    ? submit!(context, showFirstError)
                    : FilledButton.icon(
                        key: const ValueKey('step-next'),
                        onPressed: _next,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(50),
                          // Arrow after the word.
                          iconAlignment: IconAlignment.end,
                        ),
                        icon: const Icon(Icons.arrow_forward),
                        label: const Text('Next'),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
    if (!widget.scrolls) return body;
    return SingleChildScrollView(child: body);
  }
}

/// "Step 2 of 3", a progress bar and the step names, the current one in
/// bold (each opens its step). Used by [SteppedForm]. Each title is on
/// screen once, so a step can hold a heading of its own.
class StepProgress extends StatelessWidget {
  final int step;
  final List<String> titles;
  final ValueChanged<int>? onOpen;
  const StepProgress({
    super.key,
    required this.step,
    required this.titles,
    this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final n = titles.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          liveRegion: true,
          label: 'Step ${step + 1} of $n: ${titles[step]}',
          excludeSemantics: true,
          child: Text(
            'Step ${step + 1} of $n',
            style: t.labelLarge?.copyWith(
              color: cs.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Gaps.v8,
        ClipRRect(
          borderRadius: BorderRadius.circular(Radii.pill),
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: (step + 1) / n),
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : Motion.normal,
            curve: Motion.curve,
            builder: (context, v, _) => LinearProgressIndicator(
              value: v,
              minHeight: 6,
              backgroundColor: cs.surfaceContainerHighest,
            ),
          ),
        ),
        Gaps.v8,
        Wrap(
          spacing: Space.xxs,
          runSpacing: Space.xxs,
          children: [
            for (var i = 0; i < n; i++)
              _StepName(
                number: i + 1,
                title: titles[i],
                current: i == step,
                done: i < step,
                onTap: onOpen == null || i == step ? null : () => onOpen!(i),
              ),
          ],
        ),
      ],
    );
  }
}

class _StepName extends StatelessWidget {
  final int number;
  final String title;
  final bool current;
  final bool done;
  final VoidCallback? onTap;
  const _StepName({
    required this.number,
    required this.title,
    required this.current,
    required this.done,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final on = current || done;
    return Semantics(
      button: onTap != null,
      selected: current,
      label: 'Step $number: $title${done ? ', done' : ''}',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.pill),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.xs,
              vertical: Space.xxs,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: on ? cs.primary : cs.surfaceContainerHighest,
                  ),
                  child: done
                      ? Icon(Icons.check, size: 14, color: cs.onPrimary)
                      : Text(
                          '$number',
                          style: t.labelSmall?.copyWith(
                            color: on ? cs.onPrimary : cs.onSurfaceVariant,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                ),
                Gaps.h8,
                Flexible(
                  child: Text(
                    title,
                    style: (current ? t.titleSmall : t.labelLarge)?.copyWith(
                      color: current ? cs.onSurface : cs.onSurfaceVariant,
                      fontWeight: current ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A section title with an optional subtitle and right-side link.
class RedesignSection extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? action;
  final bool first;
  const RedesignSection(
    this.title, {
    super.key,
    this.subtitle,
    this.action,
    this.first = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.only(top: first ? Space.xs : Space.lg, bottom: Space.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(header: true, child: Text(title, style: t.titleLarge)),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: t.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}
