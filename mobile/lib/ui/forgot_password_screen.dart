import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart' show ApiResult;
import 'validators.dart';
import 'widgets.dart';
/// UI concern (login page): "Forgot password?" asks for the email.
/// Backend (feat/password-reset): POST /auth/forgot-password emails a
/// 6-digit code that expires in 15 minutes; POST /auth/reset-password sets
/// the new password with that code.
///
/// Closes with the email when the password was changed, so the login page
/// can fill it in.
class ForgotPasswordScreen extends StatefulWidget {
  final String initialEmail;
  const ForgotPasswordScreen({super.key, this.initialEmail = ''});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _emailForm = GlobalKey<FormState>();
  final _resetForm = GlobalKey<FormState>();
  late final _email = TextEditingController(text: widget.initialEmail);
  final _code = TextEditingController();
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
  bool _codeSent = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_email, _code, _pass, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  String _problem(ApiResult r) =>
      r.status == 0 ? 'Cannot reach the server' : r.errorText;

  Future<void> _sendCode() async {
    if (!_codeSent && !_emailForm.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = await api.post(
      '/auth/forgot-password',
      body: {'email': _email.text.trim()},
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r.ok) {
        _codeSent = true;
      } else {
        _error = _problem(r);
      }
    });
    if (r.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('If that email is registered, a code was sent.')),
      );
    }
  }

  Future<void> _reset() async {
    if (!_resetForm.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = await api.post(
      '/auth/reset-password',
      body: {
        'email': _email.text.trim(),
        'code': _code.text.trim(),
        'new_password': _pass.text,
        'confirm_password': _confirm.text,
      },
    );
    if (!mounted) return;
    if (r.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password changed. You can now log in.')),
      );
      Navigator.of(context).pop(_email.text.trim());
      return;
    }
    setState(() {
      _busy = false;
      _error = _problem(r);
    });
  }

  /// Same rule and wording as the register screen.
  Widget _passwordRules(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final p = _pass.text;
    Widget rule(String text, bool ok) => Padding(
      padding: const EdgeInsets.only(bottom: Space.xxs),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 18,
            color: ok ? cs.primary : cs.onSurfaceVariant,
          ),
          Gaps.h8,
          Text(
            text,
            style: t.bodySmall?.copyWith(
              color: ok ? cs.primary : cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md, left: Space.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          rule('8 to 64 characters', p.length >= 8 && p.length <= 64),
          rule('At least one capital letter', RegExp(r'[A-Z]').hasMatch(p)),
          rule('At least one number', RegExp(r'\d').hasMatch(p)),
        ],
      ),
    );
  }

  Widget _gap(Widget child) =>
      Padding(padding: const EdgeInsets.only(bottom: Space.md), child: child);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Forgot password')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: ListView(
            padding: Space.page,
            children: [
              Text(
                _codeSent
                    ? 'Enter the 6-digit code sent to ${_email.text.trim()} '
                          'and choose a new password. The code expires in '
                          '15 minutes.'
                    : 'Enter the email of your account. We will email you a '
                          '6-digit code to reset your password.',
                style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
              Gaps.v16,
              if (!_codeSent)
                Form(
                  key: _emailForm,
                  child: _gap(
                    AppTextField(
                      key: const ValueKey('forgot-email'),
                      controller: _email,
                      label: 'Email',
                      icon: Icons.mail_outline,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      validator: Validators.email,
                    ),
                  ),
                )
              else
                Form(
                  key: _resetForm,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _gap(
                        AppTextField(
                          key: const ValueKey('forgot-code'),
                          controller: _code,
                          label: '6-digit code',
                          icon: Icons.pin_outlined,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(6),
                          ],
                          validator: (v) =>
                              RegExp(r'^\d{6}$').hasMatch((v ?? '').trim())
                              ? null
                              : 'Enter the 6-digit code from the email',
                        ),
                      ),
                      _gap(
                        AppTextField(
                          key: const ValueKey('forgot-new-password'),
                          controller: _pass,
                          label: 'New password',
                          password: true,
                          validator: Validators.newPassword,
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      _passwordRules(context),
                      _gap(
                        AppTextField(
                          key: const ValueKey('forgot-confirm-password'),
                          controller: _confirm,
                          label: 'Confirm new password',
                          password: true,
                          validator: (v) =>
                              Validators.confirmPassword(v, _pass.text),
                        ),
                      ),
                    ],
                  ),
                ),
              if (_error != null) ...[
                Text(_error!, style: TextStyle(color: cs.error)),
                Gaps.v12,
              ],
              AppButton(
                _codeSent ? 'Reset password' : 'Send code',
                key: const ValueKey('forgot-submit'),
                onPressed: _busy ? null : (_codeSent ? _reset : _sendCode),
                loading: _busy,
                expand: true,
              ),
              if (_codeSent) ...[
                Gaps.v8,
                Wrap(
                  alignment: WrapAlignment.center,
                  children: [
                    TextButton(
                      onPressed: _busy ? null : _sendCode,
                      child: const Text('Send a new code'),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                              _codeSent = false;
                              _error = null;
                            }),
                      child: const Text('Use a different email'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
