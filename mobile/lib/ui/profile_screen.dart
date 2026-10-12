import 'package:flutter/material.dart';

import '../design/gallery_screen.dart';
import '../dev_console.dart';
import 'theme_toggle.dart';
import 'widgets.dart';
import 'change_password_screen.dart';

/// Profile tab for every role (Ivan: settings-list style). From the top:
/// "Settings" with the sun/moon toggle, your account card (tap it for
/// Manage account), Security, About, and Log out.
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
    if (!api.loggedIn) return _page(context, account: const _GuestCard());
    return Loader(
      load: [() => api.get('/auth/me'), api.lookupsResult],
      builder: (context, data) {
        final me = Map<String, dynamic>.from(data[0] as Map);
        final names = Names(Map<String, dynamic>.from(data[1] as Map));
        return _page(
          context,
          account: _AccountCard(
            me: me,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ManageAccountScreen(me: me, names: names),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _page(BuildContext context, {required Widget account}) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<bool>(
      valueListenable: ProfileScreen.devToolsShown,
      builder: (context, devTools, _) => ListView(
        padding: Space.page,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        'Settings',
                        style: t.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      'Manage your account',
                      style: t.bodyMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              // Ivan: light / dark mode in the top-right corner.
              const SunMoonToggle(),
            ],
          ),
          Gaps.v24,
          account,
          if (api.loggedIn) ...[
            Gaps.v16,
            const _SecurityCard(),
          ],
          Gaps.v16,
          SettingsGroup(
            children: [
              SettingsRow(
                key: const ValueKey('about-nexaaid'),
                icon: Icons.info_outline,
                title: 'About NexaAid',
                subtitle:
                    'Disaster relief coordination for Mandaue City · '
                    'Version 1.0.0',
                onTap: _tapAbout,
                chevron: false,
              ),
            ],
          ),
          if (devTools) ...[
            const SectionHeader('Developer tools'),
            const _DevTools(),
          ],
          Gaps.v16,
          SettingsGroup(
            children: [
              SettingsRow(
                icon: Icons.logout,
                title: api.loggedIn ? 'Log out' : 'Back to start',
                color: api.loggedIn ? cs.error : null,
                onTap: api.logout,
              ),
            ],
          ),
          Gaps.v24,
        ],
      ),
    );
  }
}

/// A rounded card of settings rows with thin lines between them.
class SettingsGroup extends StatelessWidget {
  final List<Widget> children;
  const SettingsGroup({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 56),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// One settings line: icon, title, optional subtitle, and a chevron when
/// it opens something.
class SettingsRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Color? color; // e.g. red for Log out
  final bool chevron;

  const SettingsRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.color,
    this.chevron = true,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      minTileHeight: 56,
      leading: Icon(icon, color: color ?? cs.onSurfaceVariant),
      title: Text(title, style: TextStyle(color: color)),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: onTap != null && chevron
          ? Icon(Icons.chevron_right, color: color ?? cs.onSurfaceVariant)
          : null,
      onTap: onTap,
    );
  }
}

String _initials(String name) => name
    .split(RegExp(r'\s+'))
    .where((w) => w.isNotEmpty)
    .take(2)
    .map((w) => w[0].toUpperCase())
    .join();

String _fullName(Map<String, dynamic> me) =>
    '${me['first_name'] ?? ''} ${me['last_name'] ?? ''}'.trim();

/// Your name and email; tap it to open Manage account.
class _AccountCard extends StatelessWidget {
  final Map<String, dynamic> me;
  final VoidCallback onTap;
  const _AccountCard({required this.me, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final name = _fullName(me);
    return Semantics(
      button: true,
      label: 'Manage account',
      child: AppCard(
        onTap: onTap,
        child: Row(
          children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: cs.primaryContainer,
              child: Text(
                _initials(name).isEmpty ? '?' : _initials(name),
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
                    style: t.titleMedium,
                  ),
                  Text(
                    '${me['email'] ?? ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

class _GuestCard extends StatelessWidget {
  const _GuestCard();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return AppCard(
      child: Row(
        children: [
          CircleAvatar(
            radius: 26,
            backgroundColor: cs.surfaceContainerHighest,
            child: Icon(Icons.person_outline, color: cs.onSurfaceVariant),
          ),
          Gaps.h16,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Guest donor', style: t.titleMedium),
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

/// Manage account (view only for now): your photo initials, name and
/// role, then your details. There is no endpoint to change them yet.
class ManageAccountScreen extends StatelessWidget {
  final Map<String, dynamic> me;
  final Names names;
  const ManageAccountScreen({super.key, required this.me, required this.names});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final name = _fullName(me);
    final barangayId = me['assigned_barangay_id'];
    String? text(Object? v) {
      final s = '${v ?? ''}'.trim();
      return s.isEmpty ? null : s;
    }

    final rows = <(IconData, String, String)>[
      if (text(me['username']) case final u?)
        (Icons.alternate_email, 'Username', u),
      (Icons.badge_outlined, 'Role', '${me['role_name'] ?? '-'}'),
      if (barangayId != null)
        (
          Icons.location_city_outlined,
          'Assigned barangay',
          names.of('barangays', barangayId, fallback: 'Barangay #$barangayId'),
        ),
    ];
    final private = <(IconData, String, String)>[
      (Icons.person_outline, 'Name', name.isEmpty ? '-' : name),
      (Icons.mail_outline, 'Email', '${me['email'] ?? '-'}'),
      if (text(me['contact_number']) case final n?)
        (Icons.phone_outlined, 'Phone number', n),
    ];

    Widget group(List<(IconData, String, String)> items) => AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 56),
            ListTile(
              minTileHeight: 64,
              leading: Icon(items[i].$1, color: cs.onSurfaceVariant),
              title: Text(
                items[i].$2,
                style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
              subtitle: Text(items[i].$3, style: t.bodyLarge),
            ),
          ],
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Manage account')),
      body: ListView(
        padding: Space.page,
        children: [
          Center(
            child: CircleAvatar(
              radius: 44,
              backgroundColor: cs.primaryContainer,
              child: Text(
                _initials(name).isEmpty ? '?' : _initials(name),
                style: t.headlineMedium?.copyWith(
                  color: cs.onPrimaryContainer,
                ),
              ),
            ),
          ),
          Gaps.v12,
          Text(
            name.isEmpty ? '${me['email']}' : name,
            textAlign: TextAlign.center,
            style: t.titleLarge,
          ),
          Gaps.v24,
          group(rows),
          SectionHeader(
            'Private information',
            action: Tooltip(
              message: 'Only you and the NexaAid administrator can see this.',
              triggerMode: TooltipTriggerMode.tap,
              child: Icon(
                Icons.info_outline,
                size: 20,
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
          group(private),
          Gaps.v16,
          Text(
            'Need to change something? Contact the NexaAid administrator.',
            textAlign: TextAlign.center,
            style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          Gaps.v24,
        ],
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

/// I1 (Module 1.2): change password. Shows a warning while the account
/// still has the temporary password the Administrator gave it.
class _SecurityCard extends StatelessWidget {
  const _SecurityCard();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AppCard(
      padding: EdgeInsets.zero,
      child: ListenableBuilder(
        listenable: api,
        builder: (context, _) => ListTile(
          key: const ValueKey('change-password'),
          minTileHeight: 56,
          leading: Icon(
            api.mustChangePassword
                ? Icons.warning_amber_rounded
                : Icons.lock_outline,
            color: api.mustChangePassword ? cs.error : cs.onSurfaceVariant,
          ),
          title: const Text('Security'),
          subtitle: Text(
            api.mustChangePassword
                ? 'Required: you are still using a temporary password'
                : 'Change your password',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) =>
                  ChangePasswordScreen(forced: api.mustChangePassword),
            ),
          ),
        ),
      ),
    );
  }
}
