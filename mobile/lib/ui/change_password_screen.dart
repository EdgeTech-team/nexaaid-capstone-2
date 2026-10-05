import 'package:flutter/material.dart';

import 'validators.dart';
import 'widgets.dart';

/// I1 (Module 1.2): change the password.
///
/// Opened from Profile > Change password, and opened automatically after
/// logging in with the temporary password the Administrator gave
/// ([forced] = true: no back button, only Log out). The backend repeats
/// every rule (api/v1/account_router.py).
class ChangePasswordScreen extends StatefulWidget {
  final bool forced;
  const ChangePasswordScreen({super.key, this.forced = false});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _show = false;
  bool _busy = false;

  @override
  void dispose() {
    _current.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final r = await act(
      context,
      () => api.changePassword(_current.text, _new.text, _confirm.text),
      success: 'Password changed',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (r.ok) Navigator.of(context).pop();
  }

  Widget _field(
    TextEditingController c,
    String label,
    String? Function(String?) rule, {
    Key? key,
    TextInputAction action = TextInputAction.next,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: TextFormField(
        key: key,
        controller: c,
        obscureText: !_show,
        enableSuggestions: false,
        autocorrect: false,
        textInputAction: action,
        onFieldSubmitted: action == TextInputAction.done ? (_) => _submit() : null,
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
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !widget.forced,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: !widget.forced,
          title: const Text('Change password'),
          actions: [
            if (widget.forced)
              TextButton(onPressed: api.logout, child: const Text('Log out')),
          ],
        ),
        body: Form(
          key: _form,
          child: ListView(
            padding: Space.page,
            children: [
              if (widget.forced) ...[
                AppCard(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline, color: cs.primary),
                      Gaps.h12,
                      const Expanded(
                        child: Text(
                          'You logged in with a temporary password from the '
                          'Administrator. Set your own password to continue.',
                        ),
                      ),
                    ],
                  ),
                ),
                Gaps.v16,
              ],
              _field(
                _current,
                widget.forced ? 'Temporary password' : 'Current password',
                (v) => (v ?? '').isEmpty ? 'Enter your current password' : null,
                key: const ValueKey('pw-current'),
              ),
              _field(_new, 'New password', (v) {
                final e = Validators.newPassword(v);
                if (e != null) return e;
                if (v == _current.text) return 'Use a different password';
                return null;
              }, key: const ValueKey('pw-new')),
              _field(
                _confirm,
                'Confirm new password',
                (v) => Validators.confirmPassword(v, _new.text),
                key: const ValueKey('pw-confirm'),
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
                'Save new password',
                key: const ValueKey('pw-save'),
                icon: Icons.check,
                loading: _busy,
                expand: true,
                onPressed: _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}