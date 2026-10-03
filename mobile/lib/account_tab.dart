import 'package:flutter/material.dart';

import 'api.dart';
import 'common.dart';

/// Test accounts in Neon (one per role). TEST ONLY: remove before the demo.
const testAccounts = <String, String>{
  'testadmin@gmail.com': Roles.admin,
  'halberz43@gmail.com': Roles.donor,
  'maria.santos@helpinghands.org': Roles.org,
  'cmo.test@example.com': Roles.cmo,
  'csws.test@example.com': Roles.cswsMain,
  'rico.test@example.com': Roles.cswsUnit,
  'ana.test@example.com': Roles.barangay,
  'drrmo.test@example.com': Roles.drrmo,
};

class AccountTab extends StatefulWidget {
  const AccountTab({super.key});

  @override
  State<AccountTab> createState() => _AccountTabState();
}

class _AccountTabState extends State<AccountTab> {
  final api = Api.instance;
  late final baseC = TextEditingController(text: api.baseUrl);
  final emailC = TextEditingController(text: 'testadmin@gmail.com');
  final passC = TextEditingController(text: 'testpass123');
  bool busy = false;
  ApiResult? result;

  Future<void> run(Future<ApiResult> Function() f) async {
    setState(() => busy = true);
    final r = await f();
    if (!mounted) return;
    setState(() {
      busy = false;
      result = r;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: api,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Server',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: baseC,
                    decoration: const InputDecoration(
                      labelText: 'API base URL',
                      hintText: 'Android emulator: http://10.0.2.2:8000',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton(
                      onPressed: busy
                          ? null
                          : () {
                              api.setBase(baseC.text);
                              run(() => api.get('/health'));
                            },
                      child: const Text('Save & ping /health'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Login (POST /token)',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Pick a test account to switch roles. All test accounts '
                    'use testpass123 unless you changed it in Neon.',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final e in testAccounts.entries)
                        ActionChip(
                          label: Text(
                            e.value,
                            style: const TextStyle(fontSize: 12),
                          ),
                          onPressed: () => setState(() => emailC.text = e.key),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: emailC,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: passC,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      FilledButton(
                        onPressed: busy
                            ? null
                            : () => run(() async {
                                api.logout(); // never reuse an old token
                                return api.login(emailC.text, passC.text);
                              }),
                        child: const Text('Login'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: api.loggedIn ? api.logout : null,
                        child: const Text('Logout (guest)'),
                      ),
                    ],
                  ),
                  if (api.loggedIn)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Logged in as ${api.email}\nRole: ${api.role ?? "?"}',
                      ),
                    ),
                  if (busy)
                    const Padding(
                      padding: EdgeInsets.only(top: 10),
                      child: LinearProgressIndicator(),
                    ),
                  if (result != null) ResultBox(result!),
                ],
              ),
            ),
          ),
          ApiForm(
            title: 'Register a donor',
            subtitle: 'POST /auth/register/donor',
            fields: const [
              F('first_name', 'First name'),
              F('last_name', 'Last name'),
              F('email', 'Email'),
              F('password', 'Password (min 8)', obscure: true),
              F('contact_number', 'Contact number (min 7)'),
            ],
            button: 'Register donor',
            onSubmit: (v) => api.post(
              '/auth/register/donor',
              body: {
                'first_name': v.s('first_name'),
                'last_name': v.s('last_name'),
                'email': v.s('email'),
                'password': v.raw['password'],
                'contact_number': v.s('contact_number'),
              },
            ),
          ),
          ApiForm(
            title: 'Register a relief organization',
            subtitle: 'POST /auth/register/organization  (starts as Pending)',
            fields: const [
              F('org_name', 'Organization name'),
              F('organization_type', 'Type', initial: 'NGO'),
              F('address', 'Address'),
              F('contact_person', 'Contact person'),
              F('registration_no', 'Registration no. (unique)'),
              F('contact_email', 'Contact email (login)'),
              F('password', 'Password (min 8)', obscure: true),
              F('contact_number', 'Contact number'),
            ],
            button: 'Register organization',
            onSubmit: (v) => api.post(
              '/auth/register/organization',
              body: {
                for (final k in const [
                  'org_name',
                  'organization_type',
                  'address',
                  'contact_person',
                  'registration_no',
                  'contact_email',
                  'contact_number',
                ])
                  k: v.s(k),
                'password': v.raw['password'],
              },
            ),
          ),
        ],
      ),
    );
  }
}
