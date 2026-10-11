import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import 'input_formatters.dart';
import 'private_file_view.dart';
import 'upload_field.dart';
import 'validators.dart';
import 'widgets.dart';

/// UC-A1 Manage Internal Accounts (adviser items 3 and 4).
///
/// [AccountsScreen] creates an office-based account; [AccountEditScreen]
/// edits any account with the same rules. The backend repeats every rule
/// (schemas/user_schema.py, api/v1/admin_router.py).
///
/// No password is typed here. When an account is created the server
/// generates a temporary password and emails it to the staff member.

/// Roles an Administrator may give (backend INTERNAL_ROLES).
const internalRoles = [
  Roles.cswsUnit,
  Roles.cswsMain,
  Roles.cmo,
  Roles.drrmo,
  Roles.barangay,
];

/// Accounts made before first/last names were split (e.g. organization
/// contacts) have the whole name in first_name and an empty last_name:
/// "Maria Santos" / "". The edit form then starts with first = everything
/// except the last word, last = the last word. Only the form is pre-filled;
/// nothing changes in the database until the Administrator taps Save.
(String, String) splitLegacyName(String first, String last) {
  final f = first.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (last.trim().isNotEmpty || !f.contains(' ')) return (first, last);
  final i = f.lastIndexOf(' ');
  return (f.substring(0, i), f.substring(i + 1));
}

/// Create an internal account (the "New account" tab of Accounts).
class AccountsScreen extends StatelessWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [api.lookupsResult],
      builder: (context, data) =>
          AccountForm(names: Names(Map<String, dynamic>.from(data[0] as Map))),
    );
  }
}

/// Edit every field of an account (UC-A1 step 5).
class AccountEditScreen extends StatelessWidget {
  final int userId;
  const AccountEditScreen({super.key, required this.userId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit account')),
      body: Loader(
        load: [
          () => api.get('/admin/users/$userId'),
          () => api.get('/admin/users/$userId/documents'),
          api.lookupsResult,
        ],
        builder: (context, data) {
          final docs = (data[1] as List).cast<Map>();
          return AccountForm(
            user: Map<String, dynamic>.from(data[0] as Map),
            card: docs
                .where((d) => d['purpose'] == 'employee_id_card')
                .firstOrNull,
            names: Names(Map<String, dynamic>.from(data[2] as Map)),
          );
        },
      ),
    );
  }
}

/// The form itself (public so widget tests can open it without a server).
class AccountForm extends StatefulWidget {
  final Map<String, dynamic>? user; // null = create
  final Map? card; // current employee ID card (edit)
  final Names names;
  const AccountForm({super.key, this.user, this.card, required this.names});

  @override
  State<AccountForm> createState() => AccountFormState();
}

class AccountFormState extends State<AccountForm> {
  final _form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> c;
  late String? role;
  String? brgyId;
  UploadedFile? card;
  bool busy = false;
  bool _triedSubmit = false;
  int _uploadKey = 0; // new key resets the UploadField after a save

  Map<String, dynamic>? get u => widget.user;
  bool get creating => u == null;
  String? get currentRole => u?['role'] as String?;
  bool get isStaff =>
      creating ||
      internalRoles.contains(currentRole) ||
      currentRole == Roles.admin;

  /// Administrators keep their role (and nobody changes their own role).
  bool get roleEditable =>
      creating ||
      (internalRoles.contains(currentRole) &&
          u!['email'] != api.email?.toLowerCase());

  @override
  void initState() {
    super.initState();
    final name = splitLegacyName(
      '${u?['first_name'] ?? ''}',
      '${u?['last_name'] ?? ''}',
    );
    c = {
      'first': TextEditingController(text: name.$1),
      'last': TextEditingController(text: name.$2),
      'email': TextEditingController(text: u?['email'] ?? ''),
      'phone': TextEditingController(text: u?['contact_number'] ?? ''),
    };
    role = creating ? Roles.cswsMain : currentRole;
    brgyId = u?['assigned_barangay_id']?.toString();
  }

  @override
  void dispose() {
    for (final x in c.values) {
      x.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _triedSubmit = true);
    final cardMissing = creating && card == null;
    if (!_form.currentState!.validate() || cardMissing) return;
    setState(() => busy = true);
    final rep = role == Roles.barangay;
    final body = <String, dynamic>{
      'first_name': c['first']!.text.trim(),
      'last_name': c['last']!.text.trim(),
      'email': c['email']!.text.trim(),
      'contact_number': c['phone']!.text.trim(),
      if (roleEditable) 'role_name': role,
      if (isStaff && rep) 'assigned_barangay_id': int.parse(brgyId!),
      if (card != null) 'employee_id_card': {'file_id': card!.fileId},
    };
    final editingSelf = !creating && u!['email'] == api.email?.toLowerCase();
    final emailChanged =
        !creating && body['email'].toString().toLowerCase() != u!['email'];
    final r = await act(
      context,
      () => creating
          ? api.post('/admin/users', body: body)
          : api.patch('/admin/users/${u!['user_id']}', body: body),
      success: creating
          ? 'Account created. A temporary password was sent to ${body['email']}'
          : editingSelf && emailChanged
          ? 'Saved. Log in again with your new email.'
          : 'Changes saved',
    );
    if (!mounted) return;
    setState(() => busy = false);
    if (!r.ok) return;
    if (editingSelf && emailChanged) {
      api.logout(); // the login token holds the old email
      return;
    }
    if (creating) {
      setState(() {
        for (final t in c.values) {
          t.clear();
        }
        card = null;
        brgyId = null;
        _triedSubmit = false;
        _uploadKey++;
      });
      _form.currentState!.reset();
    } else {
      Navigator.pop(context);
    }
  }

  Widget _field(
    String key,
    String label, {
    required String? Function(String?) rule,
    IconData? icon,
    String? hint,
    String? helper,
    TextInputType? type,
    bool password = false,
    List<TextInputFormatter>? formatters,
    TextCapitalization caps = TextCapitalization.none,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: AppTextField(
        key: ValueKey('account-$key'),
        controller: c[key],
        label: label,
        icon: icon,
        hint: hint,
        helper: helper,
        keyboardType: type,
        password: password,
        inputFormatters: formatters,
        textCapitalization: caps,
        validator: rule,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final rep = role == Roles.barangay;
    final fullName = '${u?['first_name'] ?? ''} ${u?['last_name'] ?? ''}'
        .trim();

    return Form(
      key: _form,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      child: ListView(
        padding: Space.page,
        children: [
          if (creating)
            const PageHeader(
              'New internal account',
              subtitle: 'Office-based roles only (UC-A1). Donors and organizations register themselves.',
            )
          else
            Padding(
              padding: const EdgeInsets.only(bottom: Space.md),
              child: Text(
                'Editing ${fullName.isEmpty ? u!['email'] : fullName} · $currentRole',
                style: t.titleMedium,
              ),
            ),
          if (isStaff) ...[
            _Section(
              title: 'Role and assignment',
              icon: Icons.admin_panel_settings_outlined,
              children: [
                if (roleEditable)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.md),
                    child: DropdownButtonFormField<String>(
                      key: const ValueKey('account-role'),
                      initialValue: role,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Role'),
                      items: [
                        for (final r in internalRoles)
                          DropdownMenuItem(value: r, child: Text(r)),
                      ],
                      onChanged: (v) => setState(() => role = v),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.md),
                    child: Text(
                      currentRole == Roles.admin
                          ? 'Role: Administrator (cannot be changed here)'
                          : 'Role: $currentRole (you cannot change your own role)',
                      style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ),
                if (rep)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.md),
                    child: LookupDropdown(
                      list: 'barangays',
                      label: 'Assigned barangay',
                      value: brgyId,
                      names: widget.names,
                      onChanged: (v) => setState(() => brgyId = v),
                    ),
                  ),
              ],
            ),
            Gaps.v12,
          ],
          _Section(
            title: 'Personal details',
            icon: Icons.person_outline,
            children: [
              _field(
                'first',
                'First name',
                rule: (v) => Validators.personName(v, label: 'First name'),
                formatters: nameFormatters,
                caps: TextCapitalization.words,
              ),
              _field(
                'last',
                'Last name',
                rule: (v) => Validators.personName(v, label: 'Last name'),
                formatters: nameFormatters,
                caps: TextCapitalization.words,
              ),
              _field(
                'email',
                'Email',
                icon: Icons.mail_outline,
                type: TextInputType.emailAddress,
                rule: Validators.email,
              ),
              _field(
                'phone',
                'Mobile number',
                icon: Icons.phone_outlined,
                hint: '09171234567',
                type: TextInputType.phone,
                formatters: phoneFormatters,
                rule: Validators.phMobile,
              ),
            ],
          ),
          // Oct 11 notes (Dave): the separate "Employee ID" number field was
          // dropped; the employee ID card is what proves the staff member
          // works in the office.
          if (isStaff) ...[
            Gaps.v12,
            _Section(
              title: 'Employee ID card',
              icon: Icons.badge_outlined,
              subtitle: 'Proof that this person works in the office. Only this staff member and Administrators can see it.',
              children: [
                if (widget.card != null) ...[
                  PrivateFileTile(
                    label: 'Current employee ID card',
                    url: '${widget.card!['url']}',
                    contentType: '${widget.card!['content_type']}',
                  ),
                  Gaps.v16,
                ],
                UploadField(
                  key: ValueKey('employee-card-$_uploadKey'),
                  label: creating
                      ? 'Photo or scan of the card'
                      : widget.card == null
                      ? 'Employee ID card (none on file yet)'
                      : 'Replace employee ID card (optional)',
                  purpose: 'employee_id_card',
                  errorText: _triedSubmit && creating && card == null
                      ? 'Required'
                      : null,
                  onChanged: (f) => setState(() => card = f),
                ),
              ],
            ),
          ],
          if (creating) ...[
            Gaps.v12,
            AppCard(
              color: cs.primaryContainer,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.mark_email_read_outlined,
                    color: cs.onPrimaryContainer,
                  ),
                  Gaps.h12,
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Temporary password',
                          style: t.titleSmall?.copyWith(
                            color: cs.onPrimaryContainer,
                          ),
                        ),
                        Gaps.v4,
                        Text(
                          'No password is typed here. The system emails a '
                          'temporary password to the address above, and the '
                          'staff member must change it on first login.',
                          style: t.bodyMedium?.copyWith(
                            color: cs.onPrimaryContainer,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          Gaps.v24,
          AppButton(
            creating ? 'Create account' : 'Save changes',
            key: const ValueKey('account-save'),
            icon: creating ? Icons.person_add_alt_1 : Icons.check,
            loading: busy,
            expand: true,
            onPressed: _submit,
          ),
          Gaps.v24,
        ],
      ),
    );
  }
}

/// A titled group of fields, in the app's card style.
class _Section extends StatelessWidget {
  final String title;
  final IconData icon;
  final String? subtitle;
  final List<Widget> children;
  const _Section({
    required this.title,
    required this.icon,
    this.subtitle,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: cs.primary),
              Gaps.h8,
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(title, style: t.titleMedium),
                ),
              ),
            ],
          ),
          if (subtitle != null) ...[
            Gaps.v4,
            Text(
              subtitle!,
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
          Gaps.v16,
          ...children,
        ],
      ),
    );
  }
}
