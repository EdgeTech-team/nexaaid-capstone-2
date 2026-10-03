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

/// Roles an Administrator may give (backend INTERNAL_ROLES).
const internalRoles = [
  Roles.cswsUnit,
  Roles.cswsMain,
  Roles.cmo,
  Roles.drrmo,
  Roles.barangay,
];

/// Same rule as backend core/validators.clean_employee_id.
String? employeeIdRule(String? v) {
  final s = (v ?? '').trim().toUpperCase();
  if (s.isEmpty) return 'Employee ID is required';
  if (!RegExp(r'^[A-Z0-9][A-Z0-9\-]{3,19}$').hasMatch(s)) {
    return '4-20 letters, numbers or hyphens, e.g. CSWS-0042';
  }
  return null;
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
    c = {
      'first': TextEditingController(text: u?['first_name'] ?? ''),
      'last': TextEditingController(text: u?['last_name'] ?? ''),
      'email': TextEditingController(text: u?['email'] ?? ''),
      'phone': TextEditingController(text: u?['contact_number'] ?? ''),
      'employee': TextEditingController(text: u?['employee_id'] ?? ''),
      'password': TextEditingController(),
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
      if (isStaff) 'employee_id': c['employee']!.text.trim().toUpperCase(),
      if (roleEditable) 'role_name': role,
      if (isStaff && rep) 'assigned_barangay_id': int.parse(brgyId!),
      if (card != null) 'employee_id_card': {'file_id': card!.fileId},
      if (creating) 'password': c['password']!.text,
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
          ? 'Account created for ${body['email']}'
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
    return Form(
      key: _form,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      child: ListView(
        padding: Space.page,
        children: [
          if (creating)
            PageHeader(
              'New internal account',
              subtitle: 'Office-based roles only (UC-A1). Donors and organizations register themselves.',
            )
          else
            Text(
              'Editing ${u!['first_name']} ${u!['last_name']} · $currentRole',
              style: t.titleMedium,
            ),
          Gaps.v16,
          if (isStaff) ...[
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
          if (isStaff) ...[
            _field(
              'employee',
              'Employee ID',
              icon: Icons.badge_outlined,
              hint: 'e.g. CSWS-0042',
              caps: TextCapitalization.characters,
              rule: employeeIdRule,
            ),
            if (widget.card != null) ...[
              PrivateFileTile(
                label: 'Current employee ID card',
                url: '${widget.card!['url']}',
                contentType: '${widget.card!['content_type']}',
              ),
              Gaps.v16,
            ],
            Padding(
              padding: const EdgeInsets.only(bottom: Space.md),
              child: UploadField(
                key: ValueKey('employee-card-$_uploadKey'),
                label: creating
                    ? 'Employee ID card'
                    : widget.card == null
                    ? 'Employee ID card (none on file yet)'
                    : 'Replace employee ID card (optional)',
                purpose: 'employee_id_card',
                helperText: 'Photo or PDF. Only this staff member and Administrators can see it.',
                errorText: _triedSubmit && creating && card == null
                    ? 'Required'
                    : null,
                onChanged: (f) => setState(() => card = f),
              ),
            ),
          ],
          if (creating)
            _field(
              'password',
              'Temporary password',
              password: true,
              helper: 'Give it to the staff member; they should change it.',
              rule: Validators.newPassword,
            ),
          Gaps.v8,
          AppButton(
            creating ? 'Create account' : 'Save changes',
            key: const ValueKey('account-save'),
            icon: creating ? Icons.person_add_alt : Icons.save_outlined,
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
