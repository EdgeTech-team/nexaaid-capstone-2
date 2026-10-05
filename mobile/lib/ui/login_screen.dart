import 'package:flutter/material.dart';

import 'register_screen.dart';
import 'widgets.dart';

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
                Align(
                  alignment: Alignment.topRight,
                  child: IconButton(
                    tooltip: 'Server address',
                    onPressed: _server,
                    icon: const Icon(Icons.settings_outlined),
                  ),
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
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: api.continueAsGuest,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  icon: const Icon(Icons.favorite_border),
                  label: const Text('Donate as guest'),
                ),
                const SizedBox(height: 6),
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const RegisterScreen(org: false),
                        ),
                      ),
                      child: const Text('Register as donor'),
                    ),
                    const Text('·'),
                    TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const RegisterScreen(org: true),
                        ),
                      ),
                      child: const Text('Register organization'),
                    ),
                  ],
                ),
                              ],
            ),
          ),
        ),
      ),
    );
  }
}
    