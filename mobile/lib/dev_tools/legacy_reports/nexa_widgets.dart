import 'package:flutter/material.dart';

import 'nexa_theme.dart';

class GradientPage extends StatelessWidget {
  final Widget child;
  const GradientPage({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [NexaColors.gradientStart, NexaColors.gradientEnd],
          ),
        ),
        child: SafeArea(child: child),
      ),
    );
  }
}

class NexaHeader extends StatelessWidget {
  final List<Widget> actions;
  const NexaHeader({super.key, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: NexaColors.coral,
        borderRadius: BorderRadius.circular(32),
      ),
      child: Row(
        children: [
          const Text(
            'Nexaaid',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const Spacer(),
          ...actions,
        ],
      ),
    );
  }
}

class HeaderPill extends StatelessWidget {
  final String label;
  final bool filled;
  final VoidCallback? onTap;
  const HeaderPill({
    super.key,
    required this.label,
    this.filled = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: filled ? NexaColors.pink : Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(label, style: const TextStyle(fontSize: 14)),
        ),
      ),
    );
  }
}

class PriorityBadge extends StatelessWidget {
  final String? level;
  final bool large;
  const PriorityBadge({super.key, required this.level, this.large = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: large ? 20 : 12,
        vertical: large ? 12 : 5,
      ),
      decoration: BoxDecoration(
        color: priorityColor(level),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Text(
        priorityText(level),
        style: TextStyle(color: Colors.white, fontSize: large ? 16 : 12),
      ),
    );
  }
}

class FulfillmentBar extends StatelessWidget {
  final double percent; // 0-100
  const FulfillmentBar({super.key, required this.percent});

  @override
  Widget build(BuildContext context) {
    final p = percent.clamp(0, 100).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Fulfillment', style: TextStyle(fontSize: 12)),
            Text('${p.round()}%', style: const TextStyle(fontSize: 13)),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: LinearProgressIndicator(
            value: p / 100,
            minHeight: 16,
            backgroundColor: NexaColors.teal,
            valueColor: const AlwaysStoppedAnimation(NexaColors.pink),
          ),
        ),
      ],
    );
  }
}

class WhiteCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const WhiteCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(30),
      ),
      child: child,
    );
  }
}
