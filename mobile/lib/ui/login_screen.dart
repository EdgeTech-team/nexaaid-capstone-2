import 'package:flutter/material.dart';

import 'register_screen.dart';
import 'widgets.dart';

import 'package:flutter/foundation.dart' show kDebugMode;

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final emailC = TextEditingController();
  final passC = TextEditingController();
  bool busy = false;
  bool hide = true;
  String? error;

  Future<void> _login() async {
    setState(() {
      busy = true;
      error = null;
    });
    final r = await api.login(emailC.text, passC.text);
    if (!mounted) return;
    setState(() {
      busy = false;
      if (!r.ok) {
        error = r.status == 0
            ? 'Cannot reach the server at ${api.baseUrl}'
            : r.status == 401
            ? 'Incorrect email or password'
            : r.errorText;
      }
    });
  }

  Future<void> _server() async {
    final v = await formDialog(
      context,
      title: 'Server address',
      message:
          'Chrome: http://localhost:8000\n'
          'Android emulator: http://10.0.2.2:8000\n'
          'Phone: http://<your PC IP>:8000',
      fields: [DialogField('url', 'API base URL', initial: api.baseUrl)],
    );
    if (v != null) api.setBase(v['url']!);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                // Back to the landing page it was opened from (hidden when
                // there is nothing to go back to), and the light/dark toggle
                // at the far right. The server address stays reachable in
                // debug builds only, for running on Chrome vs the emulator.
                Row(
                  children: [
                    if (Navigator.of(context).canPop())
                      TextButton.icon(
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.arrow_back),
                        label: const Text('Back'),
                      ),
                    const Spacer(),
                    if (kDebugMode)
                      IconButton(
                        tooltip: 'Server address',
                        onPressed: _server,
                        icon: const Icon(Icons.settings_outlined),
                      ),
                    ValueListenableBuilder<ThemeMode>(
                      valueListenable: AppTheme.mode,
                      builder: (context, mode, _) {
                        final dark =
                            Theme.of(context).brightness == Brightness.dark;
                        return IconButton(
                          tooltip: dark ? 'Light mode' : 'Dark mode',
                          onPressed: () => AppTheme.mode.value = dark
                              ? ThemeMode.light
                              : ThemeMode.dark,
                          icon: Icon(
                            dark
                                ? Icons.light_mode_outlined
                                : Icons.dark_mode_outlined,
                          ),
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                CircleAvatar(
                  radius: 38,
                  backgroundColor: cs.primaryContainer,
                  child: Icon(
                    Icons.volunteer_activism,
                    size: 40,
                    color: cs.primary,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'NexaAid',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: cs.primary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Post-disaster relief coordination',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 28),
                TextField(
                  controller: emailC,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    prefixIcon: Icon(Icons.mail_outline),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: passC,
                  obscureText: hide,
                  onSubmitted: (_) => _login(),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      tooltip: hide ? 'Show password' : 'Hide password',
                      onPressed: () => setState(() => hide = !hide),
                      icon: Icon(
                        hide
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                    ),
                  ),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(error!, style: TextStyle(color: cs.error)),
                  ),
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: busy ? null : _login,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  child: busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Log in'),
                ),
                const SizedBox(height: 12),
                // UI concern: registering comes before guest donation and
                // stands out more than it.
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const RegisterScreen(org: false),
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ),
                        child: const Text(
                          'Register as donor',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const RegisterScreen(org: true),
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ),
                        child: const Text(
                          'Register organization',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Least highlighted option: plain text, muted color.
                TextButton.icon(
                  onPressed: api.continueAsGuest,
                  style: TextButton.styleFrom(
                    foregroundColor: cs.onSurfaceVariant,
                  ),
                  icon: const Icon(Icons.favorite_border, size: 18),
                  label: const Text('Donate as guest'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
