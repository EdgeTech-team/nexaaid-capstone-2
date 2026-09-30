import 'package:flutter/material.dart';

import '../account_tab.dart' show testAccounts;
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
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: ListView(
          children: [
            // Top bar like the wireframes: logo left, settings right.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  const NexaLogo(size: 34),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'NexaAid',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                        color: Brand.ink,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Server address',
                    onPressed: _server,
                    icon: const Icon(Icons.settings_outlined),
                  ),
                ],
              ),
            ),
            // Pink hero band from the public homepage wireframe (Fig. 44).
            Container(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Brand.pinkSoft, Colors.white],
                ),
              ),
              child: const Column(
                children: [
                  Text(
                    'NexaAid',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w800,
                      color: Brand.ink,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Digital Disaster Relief Coordination and AI-Assisted '
                    'Decision-Support System for Mandaue City.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Brand.muted, height: 1.4),
                  ),
                ],
              ),
            ),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Text(
                                'Sign in',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 16),
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
                                    tooltip: hide
                                        ? 'Show password'
                                        : 'Hide password',
                                    onPressed: () =>
                                        setState(() => hide = !hide),
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
                                  child: Text(
                                    error!,
                                    style: const TextStyle(
                                      color: Color(0xFFC62828),
                                    ),
                                  ),
                                ),
                              const SizedBox(height: 16),
                              FilledButton(
                                onPressed: busy ? null : _login,
                                style: FilledButton.styleFrom(
                                  minimumSize: const Size.fromHeight(48),
                                ),
                                child: busy
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
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
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        alignment: WrapAlignment.center,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    const RegisterScreen(org: false),
                              ),
                            ),
                            child: const Text('Register as Individual →'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const RegisterScreen(org: true),
                              ),
                            ),
                            child: const Text('Register as Organization →'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      // Demo helper: one tap logs in as each role.
                      // TEST ONLY - remove before the real demo.
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF5F7),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Brand.pinkSoft),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Demo accounts (password: testpass123)',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final e in testAccounts.entries)
                                  ActionChip(
                                    backgroundColor: Colors.white,
                                    label: Text(
                                      e.value,
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    onPressed: () {
                                      emailC.text = e.key;
                                      passC.text = 'testpass123';
                                      _login();
                                    },
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
