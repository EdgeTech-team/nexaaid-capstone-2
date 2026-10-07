import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'input_formatters.dart';
import 'upload_field.dart';
import 'validators.dart';
import 'widgets.dart';

/// UC-D1 Register Individual Donor (adviser item 2) and organization
/// registration (UC-A2).
///
/// Capstone 2 adviser comments 1.1 and 1.3: Religious and Other
/// organizations do not need a registration number or supporting document
/// (PM suggestion), and both donor and organization accounts are validated
/// automatically. The Administrator's view is for review only.
///
/// Every rule here is repeated by the backend (schemas/user_schema.py,
/// schemas/organization_schema.py), so the API can't be used to skip them.
class RegisterScreen extends StatefulWidget {
  final bool org;
  const RegisterScreen({super.key, required this.org});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

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

/// Same list as backend TYPES_WITHOUT_REQUIREMENTS. These organization types
/// may register without a registration number or supporting document.
const organizationTypesWithoutRequirements = ['Religious', 'Other'];

/// D3: Terms and Conditions shown in the dialog. Edit the wording with the
/// team and the adviser before the consultation.
const termsAndConditionsText =
    'By creating a NexaAid account you agree to the following:\n\n'
    '1. Accurate information. The details, ID photos and documents you '
    'submit must be true and belong to you or your organization.\n\n'
    '2. Responsible use. NexaAid is for disaster relief coordination. Do not '
    'submit false reports or donations, or misuse another person\'s account.\n\n'
    '3. Verification. The Administrator may review your registration, ID or '
    'supporting document, and may deactivate an account that cannot be '
    'verified.\n\n'
    '4. Donations. NexaAid records and tracks physical donations. It does not '
    'process money. Official recognition of a donation depends on the '
    'confirmation of the City Mayor\'s Office.\n\n'
    '5. Privacy. Your personal data is processed under the Data Privacy Act '
    'of 2012 (RA 10173) only to verify your registration and coordinate '
    'relief.\n\n'
    '6. Account security. Keep your password private. You are responsible '
    'for activity under your account.';

class _RegisterScreenState extends State<RegisterScreen> {
  final _form = GlobalKey<FormState>();
  final _c = <String, TextEditingController>{};
  bool busy = false;
  bool consent = false;
  bool acceptedTerms = false;
  bool _triedSubmit = false;
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
      'registration_no': () => _docsOptional && v('registration_no').isEmpty
          ? null
          : Validators.registrationNo(c('registration_no').text),
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

  /// True when the chosen organization type does not need a registration
  /// number or supporting document (Religious, Other).
  bool get _docsOptional =>
      orgType != null && organizationTypesWithoutRequirements.contains(orgType);

  /// Other organization types must upload a supporting document. Donors need
  /// the front and back of a valid ID.
  bool get _filesReady => widget.org
      ? (_docsOptional || legitimacyDoc != null)
      : (idFront != null && idBack != null);

  bool get _valid =>
      _rules.values.every((rule) => rule() == null) &&
      (widget.org ? orgType != null : true) &&
      _filesReady &&
      consent &&
      acceptedTerms;

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
      'accepted_terms': acceptedTerms,
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
                'registration_no': v('registration_no').isEmpty
                    ? null
                    : v('registration_no'),
                'contact_email': c('email').text.trim(),
                // Optional: only sent when the organization uploaded one.
                if (legitimacyDoc != null)
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
                'id_front': _ref(idFront!),
                'id_back': _ref(idBack!),
              },
            ),
      // Adviser comment 1.3: validated automatically for both.
      success: 'Account created. You can now log in.',
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

  /// [required] is false for uploads that are optional (the organization's
  /// supporting document), so no "Required" error is shown for them.
  Widget _upload(
    String label,
    String purpose,
    UploadedFile? current,
    ValueChanged<UploadedFile?> set, {
    String? helper,
    bool required = true,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: UploadField(
        key: ValueKey('upload-$purpose'),
        label: label,
        purpose: purpose,
        helperText: helper,
        errorText: required && _triedSubmit && current == null
            ? 'Required'
            : null,
        onChanged: (f) => setState(() => set(f)),
      ),
    );
  }

  /// Adviser comment 1.1: 8 to 64 characters, a capital letter, a letter
  /// and a number. Keep in sync with Validators.newPassword.
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
          rule('At least one capital letter', RegExp(r'[A-Z]').hasMatch(p)),
          rule('At least one letter', RegExp(r'[A-Za-z]').hasMatch(p)),
          rule('At least one number', RegExp(r'\d').hasMatch(p)),
        ],
      ),
    );
  }

  Widget _consent(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final what = widget.org
        ? 'my contact details and any supporting document I upload'
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

  /// D3: opens the Terms and Conditions text in a dialog.
  void _showTerms() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Terms and Conditions'),
        content: const SingleChildScrollView(
          child: Text(termsAndConditionsText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// D3: Terms and Conditions checkbox. The register button stays disabled
  /// until it is ticked, and the server refuses the request without it.
  Widget _terms(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CheckboxListTile(
            key: const ValueKey('accepted-terms'),
            value: acceptedTerms,
            onChanged: (x) => setState(() => acceptedTerms = x ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            title: const Text('I agree to the Terms and Conditions.'),
            subtitle: _triedSubmit && !acceptedTerms
                ? Text('Required', style: TextStyle(color: cs.error))
                : null,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('read-terms'),
              onPressed: _showTerms,
              child: const Text('Read the Terms and Conditions'),
            ),
          ),
        ],
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
                  ? 'Your organization account is active right away. The '
                        'Administrator may review your details later.'
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
                _docsOptional
                    ? 'Registration number (optional)'
                    : 'Registration number (SEC, DSWD, CDA...)',
                icon: Icons.badge_outlined,
              ),
              _upload(
                _docsOptional
                    ? 'Supporting document (optional)'
                    : 'Supporting document (photo or PDF)',
                'legitimacy_document',
                legitimacyDoc,
                (f) => legitimacyDoc = f,
                required: !_docsOptional,
                helper: _docsOptional
                    ? 'Optional for this organization type. Upload an SEC, '
                          'DSWD or similar certificate only if you have one. '
                          'Only the Administrator can see it.'
                    : 'e.g. SEC or DSWD certificate. Only the Administrator '
                          'can see it.',
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
            _terms(context),
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
