import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'input_formatters.dart';
import 'upload_field.dart';
import 'validators.dart';
import 'widgets.dart';

/// UC-D1 Register Individual Donor (adviser item 2) and organization
/// registration reviewed in UC-A2 (adviser item 2.1).
///
/// Every rule here is repeated by the backend (schemas/user_schema.py,
/// schemas/organization_schema.py), so the API can't be used to skip them.
class RegisterScreen extends StatefulWidget {
  final bool org;
  const RegisterScreen({super.key, required this.org});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

/// UC-D1 step 3: kinds of valid ID (same list as backend ID_TYPES).
const idTypes = [
  'PhilSys National ID',
  "Driver's License",
  'Passport',
  'UMID',
  'Postal ID',
  "Voter's ID",
  'PRC ID',
  'School ID',
  'Other',
];

/// Same list as backend ORGANIZATION_TYPES.
const organizationTypes = [
  'NGO',
  'Religious',
  'Civic',
  'Private/CSR',
  'Academic',
  'Government',
  'Other',
];

class _RegisterScreenState extends State<RegisterScreen> {
  final _form = GlobalKey<FormState>();
  final _c = <String, TextEditingController>{};
  bool busy = false;
  bool consent = false;
  bool _triedSubmit = false;
  String? idType;
  String? orgType;
  UploadedFile? idFront, idBack, legitimacyDoc;

  TextEditingController c(String k) =>
      _c.putIfAbsent(k, TextEditingController.new);
  String v(String k) => Validators.squash(c(k).text);

  @override
  void dispose() {
    for (final x in _c.values) {
      x.dispose();
    }
    super.dispose();
  }

  // ---- validation (mirrors the backend) ----------------------------------
  Map<String, String? Function()> get _rules => {
    if (widget.org) ...{
      'org_name': () => Validators.orgName(c('org_name').text),
      'org_type_other': () => orgType == 'Other'
          ? Validators.text(
              c('org_type_other').text,
              'Organization type',
              2,
              90,
            )
          : null,
      'address': () => Validators.text(c('address').text, 'Address', 10, 300),
      'first_name': () =>
          Validators.personName(c('first_name').text, label: 'First name'),
      'last_name': () =>
          Validators.personName(c('last_name').text, label: 'Last name'),
      'registration_no': () =>
          Validators.registrationNo(c('registration_no').text),
    } else ...{
      'first_name': () =>
          Validators.personName(c('first_name').text, label: 'First name'),
      'last_name': () =>
          Validators.personName(c('last_name').text, label: 'Last name'),
    },
    'email': () => Validators.email(c('email').text),
    'contact_number': () => Validators.phMobile(c('contact_number').text),
    'password': () => Validators.newPassword(c('password').text),
    'confirm_password': () => Validators.confirmPassword(
      c('confirm_password').text,
      c('password').text,
    ),
  };

  bool get _filesReady =>
      widget.org ? legitimacyDoc != null : idFront != null && idBack != null;

  bool get _valid =>
      _rules.values.every((rule) => rule() == null) &&
      (widget.org ? orgType != null : idType != null) &&
      _filesReady &&
      consent;

  void _changed([_]) => setState(() {});

  // ---- submit -------------------------------------------------------------
  Map<String, dynamic> _ref(UploadedFile f) => {
    'file_id': f.fileId,
    'claim_token': f.claimToken,
  };

  Future<void> _submit() async {
    setState(() => _triedSubmit = true);
    if (!_form.currentState!.validate() || !_valid) return;
    setState(() => busy = true);
    final common = {
      'contact_number': c('contact_number').text.trim(),
      'password': c('password').text,
      'confirm_password': c('confirm_password').text,
      'consent': consent,
    };
    final r = await act(
      context,
      () => widget.org
          ? api.post(
              '/auth/register/organization',
              body: {
                ...common,
                'org_name': v('org_name'),
                'organization_type': orgType,
                'organization_type_other': orgType == 'Other'
                    ? v('org_type_other')
                    : null,
                'address': v('address'),
                'contact_first_name': v('first_name'),
                'contact_last_name': v('last_name'),
                'registration_no': v('registration_no'),
                'contact_email': c('email').text.trim(),
                'legitimacy_document': _ref(legitimacyDoc!),
              },
            )
          : api.post(
              '/auth/register/donor',
              body: {
                ...common,
                'first_name': v('first_name'),
                'last_name': v('last_name'),
                'email': c('email').text.trim(),
                'id_type': idType,
                'id_front': _ref(idFront!),
                'id_back': _ref(idBack!),
              },
            ),
      success: widget.org
          ? 'Registration submitted. You can log in once the Administrator approves your organization.'
          : 'Account created. You can now log in.',
    );
    if (!mounted) return;
    setState(() => busy = false);
    if (r.ok) Navigator.pop(context);
  }

  // ---- fields -------------------------------------------------------------
  Widget _text(
    String key,
    String label, {
    IconData? icon,
    String? hint,
    String? helper,
    TextInputType? type,
    bool password = false,
    bool name = false,
    int maxLines = 1,
    List<TextInputFormatter>? formatters,
    Iterable<String>? autofill,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: AppTextField(
        key: ValueKey('field-$key'),
        controller: c(key),
        label: label,
        icon: icon,
        hint: hint,
        helper: helper,
        password: password,
        keyboardType: type,
        maxLines: maxLines,
        textCapitalization: name
            ? TextCapitalization.words
            : TextCapitalization.none,
        inputFormatters: name ? nameFormatters : formatters,
        autofillHints: autofill,
        validator: (_) => _rules[key]?.call(),
        onChanged: _changed,
      ),
    );
  }

  Widget _dropdown(
    String label,
    String? value,
    List<String> options,
    ValueChanged<String?> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: DropdownButtonFormField<String>(
        key: ValueKey('dropdown-$label'),
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: [
          for (final o in options) DropdownMenuItem(value: o, child: Text(o)),
        ],
        validator: (x) => x == null ? 'Please choose one' : null,
        onChanged: (x) => setState(() => onChanged(x)),
      ),
    );
  }

  Widget _upload(
    String label,
    String purpose,
    UploadedFile? current,
    ValueChanged<UploadedFile?> set, {
    String? helper,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: UploadField(
        key: ValueKey('upload-$purpose'),
        label: label,
        purpose: purpose,
        helperText: helper,
        errorText: _triedSubmit && current == null ? 'Required' : null,
        onChanged: (f) => setState(() => set(f)),
      ),
    );
  }

  Widget _passwordRules(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final p = c('password').text;
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
          rule('One uppercase letter', RegExp(r'[A-Z]').hasMatch(p)),
          rule('One lowercase letter', RegExp(r'[a-z]').hasMatch(p)),
          rule('One number', RegExp(r'\d').hasMatch(p)),
          rule('One special character', RegExp(r'[^A-Za-z0-9]').hasMatch(p)),
        ],
      ),
    );
  }

  Widget _consent(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final what = widget.org
        ? 'my contact details and the supporting document'
        : 'my contact details and my ID photos';
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: CheckboxListTile(
        key: const ValueKey('consent'),
        value: consent,
        onChanged: (x) => setState(() => consent = x ?? false),
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: EdgeInsets.zero,
        title: Text(
          'I agree that NexaAid may collect and process $what to verify '
          'my registration and coordinate relief, under the Data Privacy '
          'Act of 2012 (RA 10173).',
        ),
        subtitle: _triedSubmit && !consent
            ? Text('Required', style: TextStyle(color: cs.error))
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.org ? 'Register organization' : 'Register as donor'),
      ),
      body: Form(
        key: _form,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: ListView(
          padding: Space.page,
          children: [
            Text(
              widget.org
                  ? 'Your organization can log in after the Administrator '
                        'reviews your details and supporting document.'
                  : 'Your account is active right away. The Administrator '
                        'may review your ID later.',
              style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            Gaps.v16,
            if (widget.org) ...[
              SectionHeader('Organization'),
              _text('org_name', 'Organization name', icon: Icons.apartment),
              _dropdown('Organization type', orgType, organizationTypes, (x) {
                orgType = x;
              }),
              if (orgType == 'Other')
                _text('org_type_other', 'Please specify the type'),
              // TODO(Dave Hoyohoy): replace with the AddressField
              // (geo autocomplete) once it is merged.
              _text(
                'address',
                'Address',
                icon: Icons.place_outlined,
                hint: 'Street, barangay, Mandaue City',
                maxLines: 2,
              ),
              _text(
                'registration_no',
                'Registration number (SEC, DSWD, CDA...)',
                icon: Icons.badge_outlined,
              ),
              _upload(
                'Supporting document (photo or PDF)',
                'legitimacy_document',
                legitimacyDoc,
                (f) => legitimacyDoc = f,
                helper: 'e.g. SEC or DSWD certificate. Only the Administrator can see it.',
              ),
              SectionHeader('Contact person'),
            ] else
              SectionHeader('About you'),
            _text('first_name', 'First name', name: true),
            _text('last_name', 'Last name', name: true),
            _text(
              'email',
              'Email',
              icon: Icons.mail_outline,
              type: TextInputType.emailAddress,
              autofill: const [AutofillHints.email],
            ),
            _text(
              'contact_number',
              'Mobile number',
              icon: Icons.phone_outlined,
              hint: '09171234567',
              type: TextInputType.phone,
              formatters: phoneFormatters,
            ),
            if (!widget.org) ...[
              SectionHeader('Valid ID'),
              _dropdown('ID type', idType, idTypes, (x) => idType = x),
              _upload(
                'Valid ID (front)',
                'id_front',
                idFront,
                (f) => idFront = f,
              ),
              _upload(
                'Valid ID (back)',
                'id_back',
                idBack,
                (f) => idBack = f,
                helper:
                    'Make sure all text is readable. Only you and the '
                    'Administrator can see your ID.',
              ),
            ],
            SectionHeader('Password'),
            _text('password', 'Password', password: true),
            _passwordRules(context),
            _text('confirm_password', 'Confirm password', password: true),
            _consent(context),
            AppButton(
              widget.org ? 'Submit registration' : 'Create account',
              key: const ValueKey('register-button'),
              onPressed: _valid && !busy ? _submit : null,
              loading: busy,
              expand: true,
            ),
            Gaps.v24,
          ],
        ),
      ),
    );
  }
}
