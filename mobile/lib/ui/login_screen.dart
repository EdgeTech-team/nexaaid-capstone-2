import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'forgot_password_screen.dart';
import 'register_screen.dart';
import 'widgets.dart';

/// UI concern (new notes): the login pops up over the landing page, which
/// stays visible behind it with a slight blur. Tap outside, press Esc or
/// tap the close button to go back to the landing page.
Future<void> showLoginPopup(BuildContext context) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close log in',
    barrierColor: Colors.transparent, // the blur below draws the backdrop
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (ctx, _, _) {
      final cs = Theme.of(ctx).colorScheme;
      return SafeArea(
        child: AnimatedPadding(
          duration: const Duration(milliseconds: 120),
          padding: MediaQuery.viewInsetsOf(ctx), // room for the keyboard
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Material(
                  color: cs.surface,
                  elevation: 12,
                  borderRadius: BorderRadius.circular(24),
                  clipBehavior: Clip.antiAlias,
                  child: const LoginScreen(popup: true),
                ),
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (ctx, anim, _, card) {
      final still = MediaQuery.disableAnimationsOf(ctx);
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return AnimatedBuilder(
        animation: curved,
        child: card,
        builder: (bctx, inner) {
          final v = still ? 1.0 : curved.value;
          return Stack(
            children: [
              // The landing page behind: slightly blurred and dimmed.
              // Tapping it closes the pop-up.
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => Navigator.of(bctx).maybePop(),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 6 * v, sigmaY: 6 * v),
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.3 * v),
                    ),
                  ),
                ),
              ),
              Opacity(
                opacity: v,
                child: Transform.scale(scale: 0.96 + 0.04 * v, child: inner),
              ),
            ],
          );
        },
      );
    },
  );
}

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

  void _guest() {
    if (widget.popup) Navigator.of(context).maybePop();
    api.continueAsGuest();
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

  void _register({required bool org}) =>
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => RegisterScreen(org: org)));

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final list = ListView(
      shrinkWrap: widget.popup, // the pop-up card fits its content
      padding: const EdgeInsets.all(24),
      children: [
        // Close (pop-up) or Back (full page) on the left, the light/dark
        // toggle at the far right. The server address stays reachable in
        // debug builds only, for running on Chrome vs the emulator.
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

            ValueListenableBuilder<ThemeMode>(
              valueListenable: AppTheme.mode,
              builder: (context, mode, _) {
                final dark = Theme.of(context).brightness == Brightness.dark;
                return IconButton(
                  tooltip: dark ? 'Light mode' : 'Dark mode',
                  onPressed: () => AppTheme.mode.value = dark
                      ? ThemeMode.light
                      : ThemeMode.dark,
                  icon: Icon(
                    dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
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
        const SizedBox(height: 12),
        // UI concern: registering comes before guest donation and stands
        // out more than it.
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => _register(org: false),
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
                onPressed: () => _register(org: true),
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
          onPressed: _guest,
          style: TextButton.styleFrom(foregroundColor: cs.onSurfaceVariant),
          icon: const Icon(Icons.favorite_border, size: 18),
          label: const Text('Donate as guest'),
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
