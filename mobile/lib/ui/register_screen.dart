import 'package:flutter/material.dart';

import 'widgets.dart';

/// UC-D1 (donor) and UC-R1 (relief organization) registration.
class RegisterScreen extends StatefulWidget {
  final bool org;
  const RegisterScreen({super.key, required this.org});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _form = GlobalKey<FormState>();
  final c = <String, TextEditingController>{};
  bool busy = false;

  TextEditingController _c(String k) =>
      c.putIfAbsent(k, TextEditingController.new);

  Widget _field(
    String key,
    String label, {
    bool obscure = false,
    int min = 1,
    bool required = true,
    TextInputType? type,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: _c(key),
        obscureText: obscure,
        keyboardType: type,
        decoration: InputDecoration(labelText: label),
        validator: (v) {
          final t = v?.trim() ?? '';
          if (!required && t.isEmpty) return null;
          if (t.isEmpty) return 'Required';
          if (t.length < min) return 'At least $min characters';
          return null;
        },
      ),
    );
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => busy = true);
    String v(String k) => _c(k).text.trim();
    final r = await act(
      context,
      () => widget.org
          ? api.post(
              '/auth/register/organization',
              body: {
                'org_name': v('org_name'),
                'organization_type': v('organization_type'),
                'address': v('address'),
                'contact_person': v('contact_person'),
                'registration_no': v('registration_no'),
                'legitimacy_document_url': v('doc').isEmpty ? null : v('doc'),
                'contact_email': v('email'),
                'password': _c('password').text,
                'contact_number': v('contact_number'),
              },
            )
          : api.post(
              '/auth/register/donor',
              body: {
                'first_name': v('first_name'),
                'last_name': v('last_name'),
                'email': v('email'),
                'password': _c('password').text,
                'contact_number': v('contact_number'),
              },
            ),
      success: widget.org
          ? 'Registration submitted. It stays pending until an administrator approves it.'
          : 'Account created. You can now log in.',
    );
    if (!mounted) return;
    setState(() => busy = false);
    if (r.ok) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.org ? 'Register organization' : 'Register as donor'),
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (widget.org) ...[
              _field('org_name', 'Organization name'),
              _field('organization_type', 'Organization type (e.g. NGO)'),
              _field('address', 'Address'),
              _field('contact_person', 'Contact person'),
              _field('registration_no', 'Registration number'),
              _field(
                'doc',
                'Legitimacy document link (optional)',
                required: false,
              ),
            ] else ...[
              _field('first_name', 'First name'),
              _field('last_name', 'Last name'),
            ],
            _field('email', 'Email', type: TextInputType.emailAddress),
            _field(
              'contact_number',
              'Contact number',
              min: 7,
              type: TextInputType.phone,
            ),
            _field('password', 'Password', obscure: true, min: 8),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: busy ? null : _submit,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: const Text('Create account'),
            ),
          ],
        ),
      ),
    );
  }
}
