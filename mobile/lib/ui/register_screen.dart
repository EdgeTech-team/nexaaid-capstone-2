import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'blur_popup.dart';
import 'input_formatters.dart';
import 'location_picker.dart' show AddressAutocompleteField;
import 'login_screen.dart' show showLoginPopup;
import 'upload_field.dart';
import 'validators.dart';
import 'widgets.dart';

/// UC-D1 Register Individual Donor (adviser item 2) and organization
/// registration (UC-A2).
///
/// Capstone 2 adviser comments 1.1 and 1.3: the registration number and
/// supporting document are optional for every organization type, and are
/// hidden for Government (which is verified through a separate pathway).
/// Both donor and organization accounts are validated automatically. The
/// Administrator's view is for review only.
///
/// Every rule here is repeated by the backend (schemas/user_schema.py,
/// schemas/organization_schema.py), so the API can't be used to skip them.
///
/// UI concern (new notes): from the landing page both forms open as
/// pop-ups over the blurred page ([showRegisterPopup]), like the login.
class RegisterScreen extends StatefulWidget {
  final bool org;

  /// True when shown by [showRegisterPopup]: a close button instead of
  /// Back, and the pop-up (not this screen) makes room for the keyboard.
  final bool popup;
  const RegisterScreen({super.key, required this.org, this.popup = false});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

/// Opens donor ([org] false) or organization registration as a pop-up
/// over the landing page. Only the close button closes it, so a stray tap
/// outside doesn't lose what was typed. After a successful registration
/// the login pop-up opens so the new account can sign in right away.
Future<void> showRegisterPopup(
  BuildContext context, {
  required bool org,
}) async {
  final created = await showBlurPopup<bool>(
    context,
    label: org ? 'Close organization registration' : 'Close registration',
    dismissible: false,
    maxWidth: 560,
    maxHeight: 860,
    // Its own messenger so error messages show inside the pop-up, not
    // behind the blur.
    child: ScaffoldMessenger(child: RegisterScreen(org: org, popup: true)),
  );
  if (created != true || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      backgroundColor: AppColors.success,
      content: Text('Account created. You can now log in.'),
    ),
  );
  await showLoginPopup(context);
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

/// Same list as backend TYPES_WITHOUT_REGISTRATION. These organization types
/// are not registered like private organizations, so the registration number
/// and supporting document are hidden for them.
const organizationTypesWithoutRegistration = ['Government'];

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
      'first_name': () =>
          Validators.personName(c('first_name').text, label: 'First name'),
      'last_name': () =>
          Validators.personName(c('last_name').text, label: 'Last name'),
      // Optional: only checked when the organization typed something.
      'registration_no': () => _showDocs && v('registration_no').isNotEmpty
          ? Validators.registrationNo(c('registration_no').text)
          : null,
    } else ...{
      'first_name': () =>
          Validators.personName(c('first_name').text, label: 'First name'),
      'last_name': () =>
          Validators.personName(c('last_name').text, label: 'Last name'),
    },
    'email': () => Validators.email(c('email').text),
    // Both donors and organizations may enter an address. It is optional,
    // but when something is typed it must still be 10 to 300 characters.
    'address': () => v('address').isEmpty
        ? null
        : Validators.text(c('address').text, 'Address', 10, 300),
    'contact_number': () => Validators.phMobile(c('contact_number').text),
    'password': () => Validators.newPassword(c('password').text),
    'confirm_password': () => Validators.confirmPassword(
      c('confirm_password').text,
      c('password').text,
    ),
  };

  /// True when the registration number and supporting document fields are
  /// shown: any chosen type except Government. Both are optional.
  bool get _showDocs =>
      orgType != null &&
      !organizationTypesWithoutRegistration.contains(orgType);

  /// Organizations never need to upload anything. Donors need the front and
  /// back of a valid ID.
  bool get _filesReady =>
      widget.org ? true : (idFront != null && idBack != null);

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
                // Optional: only sent when filled in.
                if (v('address').isNotEmpty) 'address': v('address'),
                'contact_first_name': v('first_name'),
                'contact_last_name': v('last_name'),
                'contact_email': c('email').text.trim(),
                // Optional: only sent when the organization filled them in.
                if (_showDocs && v('registration_no').isNotEmpty)
                  'registration_no': v('registration_no'),
                if (_showDocs && legitimacyDoc != null)
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
                // Optional: only sent when filled in.
                if (v('address').isNotEmpty) 'address': v('address'),
                'id_front': _ref(idFront!),
                'id_back': _ref(idBack!),
              },
            ),
      // Adviser comment 1.3: validated automatically for both.
      success: 'Account created. You can now log in.',
    );
    if (!mounted) return;
    setState(() => busy = false);
    if (r.ok) Navigator.pop(context, true);
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

  /// Address field with suggestions (OpenStreetMap through the backend),
  /// shared with the donate screen. Used by donors and organizations. It is
  /// optional.
  Widget _address() {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: AddressAutocompleteField(
        key: const ValueKey('field-address'),
        controller: c('address'),
        label: 'Address (optional)',
        hint: 'Start typing: street, barangay, municipality',
        icon: Icons.place_outlined,
        validator: (_) => _rules['address']?.call(),
        onChanged: (_) => _changed(),
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

  /// D2: shows the relaxed rule (8 to 64 characters, a letter and a number).
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
      // In the pop-up, the pop-up itself moves up for the keyboard.
      resizeToAvoidBottomInset: !widget.popup,
      appBar: AppBar(
        automaticallyImplyLeading: !widget.popup,
        leading: widget.popup
            ? IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.close),
              )
            : null,
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
              _text(
                'org_name',
                'Organization name',
                icon: Icons.apartment,
                formatters: orgNameFormatters,
              ),
              _dropdown('Organization type', orgType, organizationTypes, (x) {
                orgType = x;
                // Clear the hidden values when the type does not use them.
                if (organizationTypesWithoutRegistration.contains(x)) {
                  c('registration_no').clear();
                  legitimacyDoc = null;
                }
              }),
              if (orgType == 'Other')
                _text('org_type_other', 'Please specify the type'),
              _address(),
              // Optional for every type except Government (hidden).
              if (_showDocs) ...[
                _text(
                  'registration_no',
                  'Registration number (optional)',
                  icon: Icons.badge_outlined,
                  helper:
                      'SEC, DTI, CDA or DSWD number, if your '
                      'organization has one.',
                ),
                _upload(
                  'Supporting document (optional)',
                  'legitimacy_document',
                  legitimacyDoc,
                  (f) => legitimacyDoc = f,
                  required: false,
                  helper:
                      'Upload an SEC, DTI, CDA, DSWD or similar certificate '
                      'only if you have one. Only the Administrator can see '
                      'it.',
                ),
              ],
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
              _address(),
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