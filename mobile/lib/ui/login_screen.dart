import 'package:flutter/material.dart';

import 'blur_popup.dart';
import 'forgot_password_screen.dart';
import 'widgets.dart';

/// UI concern (new notes): the login pops up over the landing page, which
/// stays visible behind it with a slight blur. Tap outside, press Esc or
/// tap the close button to go back to the landing page.
///
/// Registering and guest donation are on the landing page itself, so the
/// pop-up only logs in.
Future<void> showLoginPopup(BuildContext context) => showBlurPopup<void>(
  context,
  label: 'Close log in',
  child: const LoginScreen(popup: true),
);

class LoginScreen extends StatefulWidget {
  /// True when shown by [showLoginPopup] over the landing page.
  final bool popup;
  const LoginScreen({super.key, this.popup = false});

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
    if (r.ok && widget.popup) {
      // Close the pop-up so the signed-in screens show.
      Navigator.of(context).maybePop();
      return;
    }
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

  /// UI concern: "Forgot password?" asks for the email (code by email).
  Future<void> _forgot() async {
    final email = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ForgotPasswordScreen(initialEmail: emailC.text.trim()),
      ),
    );
    if (email != null && mounted) {
      setState(() {
        emailC.text = email;
        passC.clear();
        error = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final list = ListView(
      shrinkWrap: widget.popup, // the pop-up card fits its content
      padding: const EdgeInsets.all(24),
      children: [
        // Close (pop-up) or Back (full page) on the left. No light/dark
        // toggle here (Ivan's note): it is the rightmost button of the
        // landing page header, and Profile > Appearance when signed in.
        Row(
          children: [
            if (widget.popup)
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.close),
              )
            else if (Navigator.of(context).canPop())
              TextButton.icon(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back),
                label: const Text('Back'),
              ),
            const Spacer(),

          ],
        ),
        const SizedBox(height: 8),
        CircleAvatar(
          radius: 38,
          backgroundColor: cs.primaryContainer,
          child: Icon(Icons.volunteer_activism, size: 40, color: cs.primary),
        ),
        const SizedBox(height: 14),
        Text(
          'NexaAid',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineMedium
              ?.copyWith(fontWeight: FontWeight.w800, color: cs.primary),
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
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _forgot,
            child: const Text('Forgot password?'),
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
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          child: busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Log in'),
        ),
      ],
    );

    if (widget.popup) return list;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: list,
          ),
        ),
      ),
    );
  }
}