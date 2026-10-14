import 'package:flutter/material.dart';

import 'design.dart';

/// Every design-system component on one screen, with switches for dark
/// mode and large text. Use it to check a component before using it, and
/// as the reference when reviewing PR screenshots.
/// Open it from Profile > Developer tools > Design system gallery.
class DesignGalleryScreen extends StatefulWidget {
  const DesignGalleryScreen({super.key});

  @override
  State<DesignGalleryScreen> createState() => _DesignGalleryScreenState();
}

class _DesignGalleryScreenState extends State<DesignGalleryScreen> {
  late bool dark = Theme.of(context).brightness == Brightness.dark;
  double scale = 1.0;
  bool busy = false;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Theme(
      data: dark ? AppTheme.dark() : AppTheme.light(),
      child: MediaQuery(
        data: mq.copyWith(textScaler: TextScaler.linear(scale)),
        child: Builder(builder: _page),
      ),
    );
  }

  Widget _page(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Design system'),
        actions: [
          IconButton(
            tooltip: dark ? 'Preview light mode' : 'Preview dark mode',
            onPressed: () => setState(() => dark = !dark),
            icon: Icon(
              dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
            ),
          ),
          PopupMenuButton<double>(
            tooltip: 'Text size',
            icon: const Icon(Icons.format_size),
            initialValue: scale,
            onSelected: (v) => setState(() => scale = v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 1.0, child: Text('Text 100%')),
              PopupMenuItem(value: 1.3, child: Text('Text 130%')),
              PopupMenuItem(value: 2.0, child: Text('Text 200%')),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: Space.page,
        children: [
          Text(
            'Preview: ${dark ? 'dark' : 'light'} mode, text ${(scale * 100).round()}%',
            style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SectionHeader('Colors'),
          Wrap(
            spacing: Space.xs,
            runSpacing: Space.xs,
            children: [
              _swatch(context, 'primary', cs.primary, cs.onPrimary),
              _swatch(
                context,
                'primaryContainer',
                cs.primaryContainer,
                cs.onPrimaryContainer,
              ),
              _swatch(
                context,
                'donate (vest)',
                AppColors.vest,
                AppColors.vestInk,
              ),
              _swatch(context, 'surface', cs.surface, cs.onSurface),
              _swatch(
                context,
                'card',
                Theme.of(context).cardTheme.color ?? cs.surface,
                cs.onSurface,
              ),
              _swatch(context, 'error', cs.error, cs.onError),
            ],
          ),
          const SectionHeader('Type'),
          Text('Headline medium', style: t.headlineMedium),
          Text('Headline small', style: t.headlineSmall),
          Text('Title large', style: t.titleLarge),
          Text('Title medium', style: t.titleMedium),
          Text(
            'Body large: readable paragraph text for details.',
            style: t.bodyLarge,
          ),
          Text(
            'Body medium: default text in cards and lists.',
            style: t.bodyMedium,
          ),
          Text('Body small: secondary info and dates.', style: t.bodySmall),
          Text('Label large: buttons', style: t.labelLarge),
          const SectionHeader('Buttons'),
          AppButton('Save changes', onPressed: () {}, expand: true),
          Gaps.v8,
          AppButton(
            'Donate',
            icon: Icons.volunteer_activism_outlined,
            variant: AppButtonVariant.donate,
            onPressed: () {},
            expand: true,
          ),
          Gaps.v8,
          Wrap(
            spacing: Space.xs,
            runSpacing: Space.xs,
            children: [
              AppButton(
                'Secondary',
                variant: AppButtonVariant.secondary,
                onPressed: () {},
              ),
              AppButton(
                'Tonal',
                variant: AppButtonVariant.tonal,
                onPressed: () {},
              ),
              AppButton(
                'Decline',
                variant: AppButtonVariant.danger,
                onPressed: () {},
              ),
              AppButton(
                'Cancel',
                variant: AppButtonVariant.text,
                onPressed: () {},
              ),
              const AppButton('Disabled', onPressed: null),
              AppButton(
                'Tap to load',
                loading: busy,
                onPressed: () async {
                  setState(() => busy = true);
                  await Future<void>.delayed(const Duration(seconds: 2));
                  if (mounted) setState(() => busy = false);
                },
              ),
            ],
          ),
          const SectionHeader('Inputs'),
          const AppTextField(
            label: 'Email',
            icon: Icons.mail_outline,
            hint: 'name@gmail.com',
          ),
          Gaps.v12,
          const AppTextField(
            label: 'Password',
            icon: Icons.lock_outline,
            password: true,
            helper: 'At least 8 characters',
          ),
          Gaps.v12,
          TextFormField(
            initialValue: '0912',
            autovalidateMode: AutovalidateMode.always,
            validator: (_) => 'Enter 11 digits starting with 09',
            decoration: const InputDecoration(
              labelText: 'Phone number (error state)',
              prefixIcon: Icon(Icons.phone_outlined),
            ),
          ),
          Gaps.v12,
          DropdownButtonFormField<String>(
            initialValue: 'NGO',
            decoration: const InputDecoration(labelText: 'Organization type'),
            items: const [
              DropdownMenuItem(value: 'NGO', child: Text('NGO')),
              DropdownMenuItem(value: 'Religious', child: Text('Religious')),
            ],
            onChanged: (_) {},
          ),
          const SectionHeader('Stat cards'),
          const StatCardGrid([
            StatCard(
              label: 'Active reports',
              value: '12',
              icon: Icons.campaign_outlined,
            ),
            StatCard(
              label: 'Families affected',
              value: '1,284',
              icon: Icons.groups_outlined,
              color: Color(0xFFD9480F),
            ),
            StatCard(
              label: 'Donations received',
              value: '318',
              icon: Icons.inventory_2_outlined,
              color: Color(0xFF1F6FD1),
            ),
            StatCard(
              label: 'Deliveries completed',
              value: '47',
              icon: Icons.local_shipping_outlined,
              note: 'this month',
            ),
          ]),
          const SectionHeader(
            'Status chips',
            subtitle: 'One fixed color per status, everywhere.',
          ),
          Wrap(
            spacing: Space.xs,
            runSpacing: Space.xs,
            children: [
              for (final s in StatusColors.known) StatusChip(_title(s)),
            ],
          ),
          const SectionHeader('Priority chips'),
          const Wrap(
            spacing: Space.xs,
            runSpacing: Space.xs,
            children: [
              PriorityChip('Critical'),
              PriorityChip('High'),
              PriorityChip('Medium'),
              PriorityChip('Low'),
              PriorityChip('Needs Review'),
            ],
          ),
          const SectionHeader('Progress and timeline'),
          const AppCard(child: FulfillmentBar(delivered: 120, needed: 300)),
          Gaps.v12,
          const AppCard(
            child: StatusTimeline(
              steps: donationLifecycle,
              labels: donationLifecycleLabels,
              current: 'In Transit',
            ),
          ),
          Gaps.v12,
          const AppCard(
            child: StatusTimeline(
              steps: donationLifecycle,
              labels: donationLifecycleLabels,
              current: 'Confirmed',
              axis: Axis.vertical,
              dates: {
                'Pending': 'Oct 2, 2026 09:10',
                'Received': 'Oct 3, 2026 14:02',
                'Confirmed': 'Oct 4, 2026 10:45',
              },
            ),
          ),
          const SectionHeader('Loading'),
          const SkeletonCard(),
          const SectionHeader('Empty and error states'),
          AppCard(
            child: EmptyView(
              compact: true,
              icon: Icons.volunteer_activism_outlined,
              title: 'No donations yet',
              message: 'Pick a report that needs help and pledge goods. Your donations will show here.',
              action: AppButton(
                'Browse reports',
                variant: AppButtonVariant.secondary,
                onPressed: () {},
              ),
            ),
          ),
          Gaps.v12,
          AppCard(child: ErrorView.forStatus(0, '', onRetry: () {})),
          Gaps.v32,
        ],
      ),
    );
  }

  static String _title(String s) => s
      .split(' ')
      .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
      .join(' ');

  Widget _swatch(BuildContext context, String name, Color bg, Color fg) {
    return Container(
      width: 150,
      padding: const EdgeInsets.all(Space.sm),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Text(
        name,
        style: TextStyle(color: fg, fontWeight: FontWeight.w600),
      ),
    );
  }
}
