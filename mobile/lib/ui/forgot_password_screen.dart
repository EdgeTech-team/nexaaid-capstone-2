import 'package:flutter/material.dart';

import 'validators.dart';
import 'widgets.dart';

/// Forgot password. Step 1 asks for the email and the backend emails a
/// 6-digit code; step 2 takes the code and the new password.
/// Backend: POST /auth/forgot-password and POST /auth/reset-password.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _codeStep = false;
  bool _show = false;
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final r = await act(
      context,
      () => api.forgotPassword(_email.text),
      success: 'If that email has an account, a 6-digit code was sent.',
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r.ok) _codeStep = true;
    });
  }

  Future<void> _reset() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final r = await act(
      context,
      () => api.resetPassword(_email.text, _code.text, _new.text, _confirm.text),
      success: 'Password changed. Log in with your new password.',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (r.ok) Navigator.of(context).pop();
  }

  Widget _pw(
    TextEditingController c,
    String label,
    String? Function(String?) rule, {
    TextInputAction action = TextInputAction.next,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: TextFormField(
        controller: c,
        obscureText: !_show,
        enableSuggestions: false,
        autocorrect: false,
        textInputAction: action,
        onFieldSubmitted: action == TextInputAction.done ? (_) => _reset() : null,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.lock_outline),
        ),
        validator: rule,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Forgot password')),
      body: Form(
        key: _form,
        child: ListView(
          padding: Space.page,
          children: [
            Text(
              _codeStep
                  ? 'Enter the 6-digit code we emailed you and choose a new password. The code expires in 15 minutes.'
                  : 'Enter your account email and we will send you a 6-digit code.',
            ),
            Gaps.v16,
            TextFormField(
              key: const ValueKey('fp-email'),
              controller: _email,
              enabled: !_codeStep,
              keyboardType: TextInputType.emailAddress,
              textInputAction: _codeStep ? TextInputAction.next : TextInputAction.done,
              onFieldSubmitted: _codeStep ? null : (_) => _sendCode(),
              decoration: const InputDecoration(
                labelText: 'Email',
                prefixIcon: Icon(Icons.mail_outline),
              ),
              validator: Validators.email,
            ),
            Gaps.v16,
            if (!_codeStep)
              AppButton(
                'Send code',
                key: const ValueKey('fp-send'),
                icon: Icons.send,
                loading: _busy,
                expand: true,
                onPressed: _sendCode,
              )
            else ...[
              TextFormField(
                key: const ValueKey('fp-code'),
                controller: _code,
                keyboardType: TextInputType.number,
                maxLength: 6,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: '6-digit code',
                  prefixIcon: Icon(Icons.pin_outlined),
                ),
                validator: (v) => RegExp(r'^\d{6}$').hasMatch((v ?? '').trim())
                    ? null
                    : 'Enter the 6-digit code',
              ),
              Gaps.v8,
              _pw(_new, 'New password', Validators.newPassword),
              _pw(
                _confirm,
                'Confirm new password',
                (v) => Validators.confirmPassword(v, _new.text),
                action: TextInputAction.done,
              ),
              CheckboxListTile(
                value: _show,
                onChanged: (v) => setState(() => _show = v ?? false),
                title: const Text('Show passwords'),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
              Gaps.v8,
              AppButton(
                'Reset password',
                key: const ValueKey('fp-reset'),
                icon: Icons.check,
                loading: _busy,
                expand: true,
                onPressed: _reset,
              ),
              TextButton(
                onPressed: _busy ? null : () => setState(() => _codeStep = false),
                child: const Text('Use a different email or send a new code'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
