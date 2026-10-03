import 'package:flutter/material.dart';

import '../tokens.dart';
import 'controls.dart';
import 'display.dart';

/// Grey placeholder that gently pulses while data loads.
/// Stays still when the phone's "remove animations" setting is on.
class Skeleton extends StatefulWidget {
  final double? width;
  final double height;
  final double radius;
  const Skeleton({
    super.key,
    this.width,
    this.height = 14,
    this.radius = Radii.sm,
  });

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);
  late final Animation<double> _fade = Tween(
    begin: 0.45,
    end: 1.0,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final box = Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(widget.radius),
      ),
    );
    if (MediaQuery.disableAnimationsOf(context)) return box;
    return FadeTransition(opacity: _fade, child: box);
  }
}

/// Card-shaped skeleton matching a typical list card.
class SkeletonCard extends StatelessWidget {
  final double height;
  const SkeletonCard({super.key, this.height = 120});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: SizedBox(
        height: height - Space.md * 2,
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Skeleton(width: 180, height: 18),
            Gaps.v12,
            Skeleton(height: 12),
            Gaps.v8,
            Skeleton(width: 220, height: 12),
            Spacer(),
            Skeleton(height: 8, radius: Radii.pill),
          ],
        ),
      ),
    );
  }
}

/// Scrollable list of skeleton cards: the default loading state.
class SkeletonList extends StatelessWidget {
  final int count;
  const SkeletonList({super.key, this.count = 4});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Loading',
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: Space.page,
        itemCount: count,
        separatorBuilder: (_, _) => Gaps.v12,
        itemBuilder: (_, _) => const SkeletonCard(),
      ),
    );
  }
}

/// Nothing to show yet. Say what will appear here and what to do next.
class EmptyView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  final bool compact;

  const EmptyView({
    super.key,
    required this.title,
    this.message,
    this.icon = Icons.inbox_outlined,
    this.action,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.symmetric(
        vertical: compact ? Space.lg : Space.xxl,
        horizontal: Space.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: compact ? 48 : 64,
            height: compact ? 48 : 64,
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              size: compact ? 24 : 30,
              color: cs.onSurfaceVariant,
            ),
          ),
          Gaps.v16,
          Text(
            title,
            textAlign: TextAlign.center,
            style: compact ? t.titleMedium : t.titleLarge,
          ),
          if (message != null) ...[
            Gaps.v8,
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Text(
                message!,
                textAlign: TextAlign.center,
                style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
          ],
          if (action != null) ...[Gaps.v16, action!],
        ],
      ),
    );
  }
}

/// Something failed. Say what happened and offer a way forward.
class ErrorView extends StatelessWidget {
  final String title;
  final String message;
  final VoidCallback? onRetry;
  final Widget? secondary;

  const ErrorView({
    super.key,
    required this.message,
    this.title = 'Couldn\'t load this',
    this.onRetry,
    this.secondary,
  });

  /// Standard texts for an [status] from ApiResult (0 = no connection).
  factory ErrorView.forStatus(
    int status,
    String detail, {
    VoidCallback? onRetry,
    Widget? secondary,
  }) {
    if (status == 0) {
      return ErrorView(
        title: 'Can\'t reach the server',
        message:
            'Check that the backend (uvicorn) is running and the server '
            'address is right, then try again.',
        onRetry: onRetry,
        secondary: secondary,
      );
    }
    if (status == 401 || status == 403) {
      return ErrorView(
        title: 'You don\'t have access to this',
        message: 'Log in with an account that has this role.',
        onRetry: onRetry,
        secondary: secondary,
      );
    }
    return ErrorView(
      message: 'The server answered with error $status: $detail',
      onRetry: onRetry,
      secondary: secondary,
    );
  }

  @override
  Widget build(BuildContext context) {
    return EmptyView(
      icon: Icons.cloud_off_outlined,
      title: title,
      message: message,
      action: Wrap(
        spacing: Space.xs,
        runSpacing: Space.xs,
        alignment: WrapAlignment.center,
        children: [
          if (onRetry != null)
            AppButton(
              'Try again',
              icon: Icons.refresh,
              variant: AppButtonVariant.tonal,
              onPressed: onRetry,
            ),
          ?secondary,
        ],
      ),
    );
  }
}
