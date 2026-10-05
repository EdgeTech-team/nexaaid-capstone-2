import 'package:flutter/material.dart';

import '../design/gallery_screen.dart';
import '../dev_console.dart';
import 'widgets.dart';

/// Profile tab for every role: who you are, appearance, log out.
///
/// The developer tools (server address, API console, design system
/// gallery) are hidden for normal use. Tap "About NexaAid" 5 times to show
/// them until the app is closed.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  /// Shared by every Profile tab until the app restarts.
  static final devToolsShown = ValueNotifier<bool>(false);

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  static const _tapsToReveal = 5;
  int _aboutTaps = 0;

  void _tapAbout() {
    if (ProfileScreen.devToolsShown.value) return;
    _aboutTaps++;
    if (_aboutTaps >= _tapsToReveal) {
      ProfileScreen.devToolsShown.value = true;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Developer tools are now shown')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!api.loggedIn) return _page(context, header: const _GuestHeader());
    return Loader(
      load: [() => api.get('/auth/me'), api.lookupsResult],
      builder: (context, data) {
        final me = Map<String, dynamic>.from(data[0] as Map);
        final names = Names(Map<String, dynamic>.from(data[1] as Map));
        return _page(
          context,
          header: _AccountHeader(me: me, names: names),
        );
      },
    );
  }

  Widget _page(BuildContext context, {required Widget header}) {
    return ValueListenableBuilder<bool>(
      valueListenable: ProfileScreen.devToolsShown,
      builder: (context, devTools, _) => ListView(
        padding: Space.page,
        children: [
          header,
          const SectionHeader('Appearance'),
          const _ThemePicker(),
          const SectionHeader('About'),
          AppCard(
            padding: EdgeInsets.zero,
            child: ListTile(
              key: const ValueKey('about-nexaaid'),
              leading: const Icon(Icons.info_outline),
              title: const Text('About NexaAid'),
              subtitle: const Text(
                'Disaster relief coordination for Mandaue City · Version 1.0.0',
              ),
              onTap: _tapAbout,
            ),
          ),
          if (devTools) ...[
            const SectionHeader('Developer tools'),
            const _DevTools(),
          ],
          Gaps.v24,
          AppButton(
            api.loggedIn ? 'Log out' : 'Back to start',
            icon: Icons.logout,
            variant: AppButtonVariant.secondary,
            expand: true,
            onPressed: api.logout,
          ),
          Gaps.v24,
        ],
      ),
    );
  }
}

class _AccountHeader extends StatelessWidget {
  final Map<String, dynamic> me;
  final Names names;
  const _AccountHeader({required this.me, required this.names});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final name = '${me['first_name'] ?? ''} ${me['last_name'] ?? ''}'.trim();
    final initials = name
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w[0].toUpperCase())
        .join();
    final barangayId = me['assigned_barangay_id'];

    Widget row(IconData icon, String label, String value) => Padding(
      padding: const EdgeInsets.only(top: Space.sm),
      child: Row(
        children: [
          Icon(icon, size: 20, color: cs.onSurfaceVariant),
          Gaps.h12,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
                Text(value, style: t.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: cs.primaryContainer,
                child: Text(
                  initials.isEmpty ? '?' : initials,
                  style: t.titleMedium?.copyWith(color: cs.onPrimaryContainer),
                ),
              ),
              Gaps.h16,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name.isEmpty ? '${me['email']}' : name,
                      style: t.titleLarge,
                    ),
                    Text(
                      '${me['role_name'] ?? ''}',
                      style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const Divider(height: Space.lg),
          row(Icons.mail_outline, 'Email', '${me['email']}'),
          if (barangayId != null)
            row(
              Icons.location_city_outlined,
              'Assigned barangay',
              names.of(
                'barangays',
                barangayId,
                fallback: 'Barangay #$barangayId',
              ),
            ),
        ],
      ),
    );
  }
}

class _GuestHeader extends StatelessWidget {
  const _GuestHeader();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return AppCard(
      child: Row(
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: cs.surfaceContainerHighest,
            child: Icon(Icons.person_outline, color: cs.onSurfaceVariant),
          ),
          Gaps.h16,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Guest donor', style: t.titleLarge),
                Text(
                  'Create an account to track your donations.',
                  style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ThemePicker extends StatelessWidget {
  const _ThemePicker();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppTheme.mode,
      builder: (context, mode, _) => SegmentedButton<ThemeMode>(
        segments: const [
          ButtonSegment(
            value: ThemeMode.system,
            icon: Icon(Icons.brightness_auto_outlined),
            label: Text('System'),
          ),
          ButtonSegment(
            value: ThemeMode.light,
            icon: Icon(Icons.light_mode_outlined),
            label: Text('Light'),
          ),
          ButtonSegment(
            value: ThemeMode.dark,
            icon: Icon(Icons.dark_mode_outlined),
            label: Text('Dark'),
          ),
        ],
        selected: {mode},
        onSelectionChanged: (s) => AppTheme.mode.value = s.first,
      ),
    );
  }
}

class _DevTools extends StatelessWidget {
  const _DevTools();

  @override
  Widget build(BuildContext context) {
    void open(Widget page) =>
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Server'),
            subtitle: Text(api.baseUrl),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.developer_mode),
            title: const Text('API console'),
            subtitle: const Text('Raw API forms and role checks'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => open(const DevConsole()),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Design system gallery'),
            subtitle: const Text(
              'Every component, in dark mode and large text',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => open(const DesignGalleryScreen()),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.visibility_off_outlined),
            title: const Text('Hide developer tools'),
            onTap: () => ProfileScreen.devToolsShown.value = false,
          ),
        ],
      ),
    );
  }
}
