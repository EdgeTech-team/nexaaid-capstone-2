import 'dart:ui' show ImageFilter;

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
    final name = splitLegacyName(
      '${u?['first_name'] ?? ''}',
      '${u?['last_name'] ?? ''}',
    );
    c = {
      'first': TextEditingController(text: name.$1),
      'last': TextEditingController(text: name.$2),
      'email': TextEditingController(text: u?['email'] ?? ''),
      'phone': TextEditingController(text: u?['contact_number'] ?? ''),
      'employee': TextEditingController(text: u?['employee_id'] ?? ''),
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

  /// Rounded, softly filled inputs with a lime focus ring. Scoped to this
  /// screen so the rest of the app keeps its own theme.
  ThemeData _fieldTheme(ThemeData base, bool dark) {
    OutlineInputBorder outline(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: color, width: width),
        );
    final idle = (dark ? Colors.white : Colors.black).withValues(alpha: .10);
    return base.copyWith(
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        filled: true,
        fillColor: dark
            ? Colors.black.withValues(alpha: .40)
            : Colors.white.withValues(alpha: .78),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: outline(idle),
        enabledBorder: outline(idle),
        focusedBorder: outline(dark ? _Brand.lime : _Brand.limeDeep, 1.8),
        errorBorder: outline(base.colorScheme.error),
        focusedErrorBorder: outline(base.colorScheme.error, 1.8),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final t = base.textTheme;
    final cs = base.colorScheme;
    final dark = base.brightness == Brightness.dark;
    final rep = role == Roles.barangay;
    final fullName = '${u?['first_name'] ?? ''} ${u?['last_name'] ?? ''}'
        .trim();

    return Theme(
      data: _fieldTheme(base, dark),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const _AuraBackdrop(),
          Form(
            key: _form,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: ListView(
              padding: Space.page.add(const EdgeInsets.only(bottom: 120)),
              children: [
                if (creating)
                  const _HeroCard(
                    icon: Icons.person_add_alt_1_rounded,
                    title: 'New internal account',
                    subtitle: 'Office-based roles only. Donors and organizations register themselves.',
                  )
                else
                  _HeroCard(
                    icon: Icons.manage_accounts_rounded,
                    title: fullName.isEmpty ? 'Edit account' : fullName,
                    subtitle: '${u!['email'] ?? ''}',
                    badge: currentRole,
                  ),
                const SizedBox(height: 16),
                if (isStaff)
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
                            borderRadius: BorderRadius.circular(16),
                            decoration: const InputDecoration(
                              labelText: 'Role',
                            ),
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
                            style: t.bodyMedium?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
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
                if (isStaff) const SizedBox(height: 14),
                _Section(
                  title: 'Personal details',
                  icon: Icons.badge_outlined,
                  children: [
                    _field(
                      'first',
                      'First name',
                      rule: (v) =>
                          Validators.personName(v, label: 'First name'),
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
                if (isStaff) ...[
                  const SizedBox(height: 14),
                  _Section(
                    title: 'Staff identification',
                    icon: Icons.verified_user_outlined,
                    children: [
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
                      UploadField(
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
                    ],
                  ),
                ],
                if (creating) ...[
                  const SizedBox(height: 14),
                  const _InfoBanner(
                    icon: Icons.mark_email_read_outlined,
                    text: 'No password needed. A temporary password is emailed to the address above as soon as you create the account.',
                  ),
                ],
                const SizedBox(height: 20),
                _PillButton(
                  key: const ValueKey('account-save'),
                  label: creating ? 'Create account' : 'Save changes',
                  icon: creating
                      ? Icons.arrow_outward_rounded
                      : Icons.check_rounded,
                  loading: busy,
                  onPressed: _submit,
                ),
                Gaps.v24,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Visual building blocks (private to this screen)
// ---------------------------------------------------------------------------

/// Palette taken from the reference: fresh lime on near-black, over a soft
/// blurred green wash.
class _Brand {
  static const lime = Color(0xFFB8F23C);
  static const limeDeep = Color(0xFF6FBF1E);
  static const ink = Color(0xFF0C0E0A);
  static const leaf = Color(0xFF3FA34D);
}

/// Blurred green background, like the out-of-focus foliage in the reference.
class _AuraBackdrop extends StatelessWidget {
  const _AuraBackdrop();

  Widget _blob(double size, Color color) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: dark
                      ? const [Color(0xFF173012), Color(0xFF060804)]
                      : const [Color(0xFFDDF3B6), Color(0xFFF5FAEA)],
                ),
              ),
            ),
          ),
          Positioned(
            top: -100,
            right: -80,
            child: _blob(300, _Brand.lime.withValues(alpha: dark ? .38 : .65)),
          ),
          Positioned(
            top: 280,
            left: -140,
            child: _blob(320, _Brand.leaf.withValues(alpha: dark ? .22 : .35)),
          ),
          Positioned(
            bottom: -120,
            right: -60,
            child: _blob(280, _Brand.lime.withValues(alpha: dark ? .16 : .40)),
          ),
        ],
      ),
    );
  }
}

/// Frosted-glass surface used for every card.
class _Glass extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  const _Glass({
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.radius = 28,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final shape = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: shape,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? .35 : .08),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: shape,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              borderRadius: shape,
              color: dark ? null : Colors.white.withValues(alpha: .60),
              gradient: dark
                  ? LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        const Color(0xFF1B2513).withValues(alpha: .84),
                        const Color(0xFF0B0E08).withValues(alpha: .90),
                      ],
                    )
                  : null,
              border: Border.all(
                color: dark
                    ? _Brand.lime.withValues(alpha: .18)
                    : Colors.white.withValues(alpha: .85),
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Glass card with a lime icon chip and a title.
class _Section extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;
  const _Section({
    required this.title,
    required this.icon,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return _Glass(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: const BoxDecoration(
                  color: _Brand.lime,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 18, color: _Brand.ink),
              ),
              const SizedBox(width: 10),
              Text(
                title,
                style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    );
  }
}

/// Black header card with a lime icon, like the dark summary cards in the
/// reference.
class _HeroCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? badge;
  const _HeroCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 20, 18, 20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1A2A10), _Brand.ink],
        ),
        border: Border.all(color: _Brand.lime.withValues(alpha: .22)),
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .25),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (badge != null) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: _Brand.lime,
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(
                      badge!,
                      style: t.labelSmall?.copyWith(
                        color: _Brand.ink,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: t.headlineSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  style: t.bodyMedium?.copyWith(
                    color: Colors.white.withValues(alpha: .66),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: _Brand.lime,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: _Brand.lime.withValues(alpha: .45),
                  blurRadius: 22,
                ),
              ],
            ),
            child: Icon(icon, color: _Brand.ink, size: 26),
          ),
        ],
      ),
    );
  }
}

/// Lime-tinted note explaining the emailed temporary password.
class _InfoBanner extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoBanner({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _Brand.lime.withValues(alpha: dark ? .14 : .32),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _Brand.lime.withValues(alpha: .75)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: const BoxDecoration(
              color: _Brand.ink,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 18, color: _Brand.lime),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: t.bodyMedium?.copyWith(height: 1.35)),
          ),
        ],
      ),
    );
  }
}

/// Black pill button with a lime action circle, like "Add to Cart".
class _PillButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool loading;
  final VoidCallback onPressed;
  const _PillButton({
    super.key,
    required this.label,
    required this.icon,
    required this.loading,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Material(
      color: _Brand.ink,
      shape: StadiumBorder(
        side: BorderSide(color: _Brand.lime.withValues(alpha: .40)),
      ),
      elevation: 8,
      shadowColor: _Brand.lime.withValues(alpha: .35),
      child: InkWell(
        borderRadius: BorderRadius.circular(99),
        onTap: loading ? null : onPressed,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(26, 8, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: t.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Container(
                width: 48,
                height: 48,
                decoration: const BoxDecoration(
                  color: _Brand.lime,
                  shape: BoxShape.circle,
                ),
                child: loading
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: _Brand.ink,
                        ),
                      )
                    : Icon(icon, color: _Brand.ink),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
