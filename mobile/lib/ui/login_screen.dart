import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'register_screen.dart';
import 'widgets.dart';

// ---------------------------------------------------------------------------
// Sign in, Join NexaAid (choose donor type) and Forgot password.
//
// On the landing page these open as pop-outs over a slightly blurred
// landing page (showLoginPopup, showJoinPopup). LoginScreen is the same
// form as a full page, for anywhere that still pushes a route.
// After a successful sign-in main.dart closes every pop-out and route
// (RoleHome replaces the landing page), so nothing here has to pop.
// ---------------------------------------------------------------------------

/// Shows [child] as a centered card over a blurred, dimmed background.
Future<T?> showBlurPopup<T>(BuildContext context, Widget child) {
  final still = MediaQuery.disableAnimationsOf(context);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.black.withValues(alpha: 0.25),
    transitionDuration: still ? Duration.zero : Motion.normal,
    pageBuilder: (ctx, _, _) => SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Space.md),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Material(
              color: Theme.of(ctx).colorScheme.surface,
              elevation: 8,
              borderRadius: BorderRadius.circular(Radii.xl),
              clipBehavior: Clip.antiAlias,
              child: child,
            ),
          ),
        ),
      ),
    ),
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: Motion.curve);
      return BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: 6 * curved.value,
          sigmaY: 6 * curved.value,
        ),
        child: FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween(begin: 0.96, end: 1.0).animate(curved),
            child: child,
          ),
        ),
      );
    },
  );
}

/// Landing page "Sign in".
Future<void> showLoginPopup(BuildContext context) => showBlurPopup<void>(
  context,
  _PopupFrame(
    child: LoginForm(
      onJoin: () {
        Navigator.of(context).pop();
        showJoinPopup(context);
      },
    ),
  ),
);

/// Landing page "Join NexaAid": choose individual donor or relief
/// organization, then open the matching registration form.
Future<void> showJoinPopup(BuildContext context) => showBlurPopup<void>(
  context,
  _PopupFrame(
    child: _JoinChooser(
      onPick: (org) {
        Navigator.of(context).pop();
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => RegisterScreen(org: org)),
        );
      },
      onSignIn: () {
        Navigator.of(context).pop();
        showLoginPopup(context);
      },
    ),
  ),
);

/// Close button row on top of every pop-out (the "back" of the pop-out).
class _PopupFrame extends StatelessWidget {
  final Widget child;
  const _PopupFrame({required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.xs, Space.xs, 0, 0),
            child: IconButton(
              tooltip: 'Back',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.lg,
            0,
            Space.lg,
            Space.lg,
          ),
          child: child,
        ),
      ],
    );
  }
}

/// Full-page version of the sign-in form: back button only. No settings and
/// no light/dark picker (that lives on the landing page and in Profile).
class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(leading: const BackButton()),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Space.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: LoginForm(onJoin: () => showJoinPopup(context)),
            ),
          ),
        ),
      ),
    );
  }
}

class LoginForm extends StatefulWidget {
  final VoidCallback onJoin;
  const LoginForm({super.key, required this.onJoin});

  @override
  State<LoginForm> createState() => _LoginFormState();
}

class _LoginFormState extends State<LoginForm> {
  final emailC = TextEditingController();
  final passC = TextEditingController();
  bool busy = false;
  String? error;

  @override
  void dispose() {
    emailC.dispose();
    passC.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (emailC.text.trim().isEmpty || passC.text.isEmpty) {
      setState(() => error = 'Enter your email and password.');
      return;
    }
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return AutofillGroup(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _BrandMark(),
          Gaps.v16,
          Text(
            'Welcome back',
            textAlign: TextAlign.center,
            style: t.headlineSmall,
          ),
          Gaps.v4,
          Text(
            'Sign in to follow your donations to the barangay.',
            textAlign: TextAlign.center,
            style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          Gaps.v24,
          AppTextField(
            controller: emailC,
            label: 'Email',
            icon: Icons.mail_outline,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.email],
          ),
          Gaps.v12,
          AppTextField(
            controller: passC,
            label: 'Password',
            icon: Icons.lock_outline,
            password: true,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.password],
            onSubmitted: (_) => _login(),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => showForgotPassword(context, emailC.text),
              child: const Text('Forgot password?'),
            ),
          ),
          if (error != null) ...[
            Text(error!, style: t.bodyMedium?.copyWith(color: cs.error)),
            Gaps.v12,
          ],
          AppButton(
            'Sign in',
            icon: Icons.login,
            expand: true,
            large: true,
            loading: busy,
            onPressed: _login,
          ),
          Gaps.v12,
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'New to NexaAid?',
                style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
              TextButton(
                onPressed: widget.onJoin,
                child: const Text('Join now'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: AppColors.vest,
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: const Icon(
        Icons.volunteer_activism,
        size: 30,
        color: AppColors.vestInk,
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Join NexaAid: pick the kind of donor account.
// ---------------------------------------------------------------------------
class _JoinChooser extends StatelessWidget {
  final ValueChanged<bool> onPick; // true = organization
  final VoidCallback onSignIn;
  const _JoinChooser({required this.onPick, required this.onSignIn});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _BrandMark(),
        Gaps.v16,
        Text('Join NexaAid', textAlign: TextAlign.center, style: t.headlineSmall),
        Gaps.v4,
        Text(
          'How will you give? You can donate to any validated report '
          'either way.',
          textAlign: TextAlign.center,
          style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
        ),
        Gaps.v24,
        _ChoiceCard(
          icon: Icons.person_outline,
          title: 'As an individual',
          subtitle: 'For yourself or your family.',
          points: const [
            'Ready to donate right after signing up',
            'Track every donation with its QR code',
          ],
          onTap: () => onPick(false),
        ),
        Gaps.v12,
        _ChoiceCard(
          icon: Icons.groups_outlined,
          title: 'As an organization',
          subtitle: 'Churches, companies, schools and relief groups.',
          points: const [
            'Give under your organization\'s name',
            'Documents are optional for some organization types',
          ],
          onTap: () => onPick(true),
        ),
        Gaps.v16,
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'Already have an account?',
              style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            TextButton(onPressed: onSignIn, child: const Text('Sign in')),
          ],
        ),
      ],
    );
  }
}

class _ChoiceCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final List<String> points;
  final VoidCallback onTap;

  const _ChoiceCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.points,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: '$title. $subtitle',
      child: Material(
        color: cs.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.lg),
          side: BorderSide(color: cs.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(Space.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: cs.primaryContainer,
                  child: Icon(icon, color: cs.onPrimaryContainer),
                ),
                Gaps.h12,
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: t.titleMedium),
                      Gaps.v4,
                      Text(
                        subtitle,
                        style: t.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      Gaps.v8,
                      for (final p in points)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.check,
                                size: 16,
                                color: StatusColors.base('Acknowledged'),
                              ),
                              Gaps.h4,
                              Expanded(child: Text(p, style: t.bodySmall)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Forgot password: POST /auth/forgot-password emails a temporary password.
// Signing in with it sends the user to Change password (must_change_password).
// ---------------------------------------------------------------------------
Future<void> showForgotPassword(BuildContext context, String email) =>
    showDialog<void>(
      context: context,
      builder: (_) => _ForgotPasswordDialog(initialEmail: email.trim()),
    );

class _ForgotPasswordDialog extends StatefulWidget {
  final String initialEmail;
  const _ForgotPasswordDialog({required this.initialEmail});

  @override
  State<_ForgotPasswordDialog> createState() => _ForgotPasswordDialogState();
}

class _ForgotPasswordDialogState extends State<_ForgotPasswordDialog> {
  late final emailC = TextEditingController(text: widget.initialEmail);
  bool busy = false;
  String? error;
  String? sent;

  @override
  void dispose() {
    emailC.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final email = emailC.text.trim();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      setState(() => error = 'Enter the email you registered with.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    final r = await api.post('/auth/forgot-password', body: {'email': email});
    if (!mounted) return;
    setState(() {
      busy = false;
      if (r.ok) {
        sent = (r.json is Map ? r.json['detail'] : null)?.toString() ??
            'Check your email for a temporary password.';
      } else {
        error = r.status == 0
            ? 'Cannot reach the server at ${api.baseUrl}'
            : r.errorText;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return AlertDialog(
      title: const Text('Forgot password?'),
      content: SizedBox(
        width: 360,
        child: sent != null
            ? Text(
                '$sent\n\nSign in with the temporary password, then choose '
                'a new one.',
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Enter your account email. We\'ll send you a temporary '
                    'password.',
                    style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  Gaps.v16,
                  AppTextField(
                    controller: emailC,
                    label: 'Email',
                    icon: Icons.mail_outline,
                    keyboardType: TextInputType.emailAddress,
                    onSubmitted: (_) => _send(),
                  ),
                  if (error != null) ...[
                    Gaps.v8,
                    Text(error!, style: t.bodySmall?.copyWith(color: cs.error)),
                  ],
                ],
              ),
      ),
      actions: sent != null
          ? [
              AppButton(
                'Back to sign in',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ]
          : [
              AppButton(
                'Cancel',
                variant: AppButtonVariant.text,
                onPressed: () => Navigator.of(context).pop(),
              ),
              AppButton(
                'Send',
                icon: Icons.send_outlined,
                loading: busy,
                onPressed: _send,
              ),
            ],
    );
  }
}
