import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../shared/widgets/blur_popup.dart';
import '../../shared/forms/input_formatters.dart';
import '../pickup/location_picker.dart' show AddressAutocompleteField;
import 'login_screen.dart' show showLoginPopup;
import '../uploads/upload_field.dart';
import '../../shared/forms/validators.dart';
import '../../shared/widgets/widgets.dart';

/// UC-D1 Register Individual Donor (adviser item 2) and organization
/// registration (UC-A2).
///
/// NF-008 (D6): the organization type is a fixed grouped list (Government /
/// Non-government). Every organization uploads the contact person's
/// valid ID (any valid ID, not only a government one); Government types
/// also upload one supporting document,
/// which stays optional for the others (adviser comment 1.1). The
/// organization signs in at once and is Unverified until the Administrator
/// reviews it (comment 1.3). The organization no longer
/// enters a registration number. Both donor and organization accounts are
/// validated automatically and sign in right after registering. The
/// Administrator's view is for review only.
///
/// Every rule here is repeated by the backend (schemas/accounts/user_schema.py,
/// schemas/accounts/organization_schema.py), so the API can't be used to skip them.
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
/// the new account is signed in automatically and goes straight to its
/// home screen. The login pop-up only opens if that sign-in fails.
Future<void> showRegisterPopup(
  BuildContext context, {
  required bool org,
}) async {
  final creds = await showBlurPopup<(String, String)>(
    context,
    label: org ? 'Close organization registration' : 'Close registration',
    dismissible: false,
    maxWidth: 560,
    maxHeight: 860,
    // Its own messenger so error messages show inside the pop-up, not
    // behind the blur.
    child: ScaffoldMessenger(child: RegisterScreen(org: org, popup: true)),
  );
  if (creds == null || !context.mounted) return;
  // The pop-up is closed first, then the new account signs in. Signing in
  // swaps the whole app to the role's home screen.
  await api.login(creds.$1, creds.$2);
  if (api.token != null || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      backgroundColor: AppColors.success,
      content: Text('Account created. You can now log in.'),
    ),
  );
  await showLoginPopup(context);
}

/// NF-008 (D6): same lists as backend schemas/accounts/organization_schema.py
/// (GOVERNMENT_TYPES, NON_GOVERNMENT_TYPES), shown as one grouped dropdown.
const governmentTypes = [
  'Barangay / Barangay Council',
  'City or Municipal Government Office',
  'National Government Agency',
  'Public School or State University',
  'Government-Owned or Controlled Corporation',
];
const otherOrganizationType = 'Other (specify)';
const nonGovernmentTypes = [
  'Non-Profit / NGO / Foundation',
  'Religious Organization',
  'Private Company or Business',
  'Private School or University',
  'Civic or Community Group',
  otherOrganizationType, // counted as Non-government
];
const organizationTypes = [...governmentTypes, ...nonGovernmentTypes];

/// 'Government' or 'Non-government' (organizations.organization_category).
String organizationCategory(String? type) =>
    governmentTypes.contains(type) ? 'Government' : 'Non-government';

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
    'for activity under your account.\n\n'
    '7. Valid ID and Door to Door. Every account uploads a valid ID (for an '
    'organization, the contact person\'s). Door to Door pickups are only '
    'for accounts with a valid ID on file, and the pickup team may ask to '
    'see it. The Administrator may delete an account with a fake ID or an '
    'invalid document, and will tell you why.';

/// Same list as backend RESERVED_USERNAMES (core/common/usernames.py).
const reservedUsernames = [
  'admin',
  'administrator',
  'nexaaid',
  'support',
  'root',
];

/// Organization login username. Same rules as backend clean_username():
/// 4 to 30 characters, starts with a letter, then letters, numbers,
/// underscores or periods. Saved in lowercase. Returns null when valid.
String? usernameError(String raw) {
  final u = raw.trim().toLowerCase();
  if (u.isEmpty) return 'Username is required';
  if (u.length < 4 || u.length > 30) return 'Use 4 to 30 characters';
  if (!RegExp(r'^[a-z][a-z0-9_.]*$').hasMatch(u)) {
    return 'Start with a letter, then use only letters, numbers, '
        'underscores or periods';
  }
  if (u.contains('..') || u.endsWith('.')) {
    return 'No two periods in a row, and do not end with a period';
  }
  if (reservedUsernames.contains(u)) return 'That username is not available';
  return null;
}

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
    _scroll.dispose();
    super.dispose();
  }

  // ---- validation (mirrors the backend) ----------------------------------
  Map<String, String? Function()> get _rules => {
    if (widget.org) ...{
      'org_name': () => Validators.orgName(c('org_name').text),
      'org_type_other': () => orgType == otherOrganizationType
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
      'username': () => usernameError(c('username').text),
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

  /// NF-008 (D6): the supporting document shows once a type is chosen. It
  /// is required for Government types and optional for the others.
  bool get _showDocs => orgType != null;
  bool get _docRequired => organizationCategory(orgType) == 'Government';

  /// Donors, and NF-008 (D6) the organization's contact person, upload the
  /// front and back of any valid ID; Government types also need the
  /// supporting document.
  bool get _filesReady =>
      idFront != null &&
      idBack != null &&
      (!widget.org || !_docRequired || legitimacyDoc != null);

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
                'organization_type_other': orgType == otherOrganizationType
                    ? v('org_type_other')
                    : null,
                // Optional: only sent when filled in.
                if (v('address').isNotEmpty) 'address': v('address'),
                'contact_first_name': v('first_name'),
                'contact_last_name': v('last_name'),
                'contact_email': c('email').text.trim(),
                // The organization's login name, saved in lowercase.
                'username': v('username').toLowerCase(),
                // Required for Government types, optional for the others.
                if (_showDocs && legitimacyDoc != null)
                  'legitimacy_document': _ref(legitimacyDoc!),
                // NF-008 (D6): the contact person's valid ID.
                'id_front': _ref(idFront!),
                'id_back': _ref(idBack!),
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
      success: widget.org
          ? 'Welcome to NexaAid! Your organization account is ready.'
          : 'Account created.',
    );
    if (!mounted) return;
    setState(() => busy = false);
    // Hands the email and password to showRegisterPopup, which signs in
    // after this pop-up has closed.
    if (r.ok) {
      Navigator.pop(context, (c('email').text.trim(), c('password').text));
    }
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

  /// NF-008 (D6): one dropdown, grouped Government / Non-government.
  Widget _typeDropdown() {
    DropdownMenuItem<String> header(String text) => DropdownMenuItem<String>(
      value: '#$text',
      enabled: false,
      child: Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.8),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: DropdownButtonFormField<String>(
        key: const ValueKey('dropdown-Organization type'),
        initialValue: orgType,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Organization type'),
        selectedItemBuilder: (context) => [
          for (final o in [
            '#Government',
            ...governmentTypes,
            '#Non-government',
            ...nonGovernmentTypes,
          ])
            Text(o.startsWith('#') ? '' : o, overflow: TextOverflow.ellipsis),
        ],
        items: [
          header('Government'),
          for (final o in governmentTypes)
            DropdownMenuItem(value: o, child: Text(o)),
          header('Non-government'),
          for (final o in nonGovernmentTypes)
            DropdownMenuItem(value: o, child: Text(o)),
        ],
        validator: (x) => x == null ? 'Please choose one' : null,
        onChanged: (x) => setState(() => orgType = x),
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
        ? "my contact details, the contact person's ID photos and any "
              'supporting document I upload'
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

  // ---- steps -------------------------------------------------------------
  // The old registration design, one step at a time. Next stays disabled
  // until the step showing is filled in, and the step names can't be tapped,
  // so no step can be skipped. Every step stays built (only the current one
  // shows), so typed text and uploaded photos are kept on Back.
  int _step = 0;
  final _scroll = ScrollController();

  bool _ok(List<String> keys) =>
      keys.every((k) => _rules[k] == null || _rules[k]!() == null);

  bool get _idsDone => idFront != null && idBack != null;

  List<_RegStep> _steps(BuildContext context) => widget.org
      ? [
          _RegStep(
            'Organization',
            _ok(['org_name', 'org_type_other', 'address']) &&
                orgType != null &&
                (!_docRequired || legitimacyDoc != null),
            [
              _text(
                'org_name',
                'Organization name',
                icon: Icons.apartment,
                formatters: orgNameFormatters,
              ),
              _typeDropdown(),
              if (orgType == otherOrganizationType)
                _text('org_type_other', 'Please specify the type'),
              _address(),
              // NF-008 (D6): required for Government types, optional for
              // the others.
              if (_showDocs)
                _docRequired
                    ? _upload(
                        'Supporting document',
                        'legitimacy_document',
                        legitimacyDoc,
                        (f) => legitimacyDoc = f,
                        helper:
                            'Required for government offices: an '
                            'authorization or endorsement letter on office '
                            'letterhead, or the contact person\'s office ID. '
                            'Only the Administrator can see it.',
                      )
                    : _upload(
                        'Supporting document (optional)',
                        'legitimacy_document',
                        legitimacyDoc,
                        (f) => legitimacyDoc = f,
                        required: false,
                        helper:
                            'Upload an SEC, DTI or CDA registration only if '
                            'you have one. Only the Administrator can see it.',
                      ),
            ],
          ),
          _RegStep(
            'Contact person',
            _ok(['first_name', 'last_name', 'email', 'contact_number']) &&
                _idsDone,
            [
              ..._personFields(),
              // The contact person uploads any valid ID, like a donor.
              SectionHeader('Contact person\'s valid ID'),
              ..._idUploads(),
            ],
          ),
          _RegStep(
            'Log in details',
            _ok(['username', 'password', 'confirm_password']) &&
                consent &&
                acceptedTerms,
            [
              _text(
                'username',
                'Username',
                icon: Icons.person_outline,
                helper:
                    '4 to 30 characters: letters, numbers, underscore or '
                    'period. Starts with a letter. You can use it or your '
                    'email to log in.',
                formatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9_.]')),
                  LengthLimitingTextInputFormatter(30),
                ],
                autofill: const [AutofillHints.newUsername],
              ),
              ..._passwordFields(context),
            ],
          ),
        ]
      : [
          _RegStep(
            'About you',
            _ok([
              'first_name',
              'last_name',
              'email',
              'contact_number',
              'address',
            ]),
            [..._personFields(), _address()],
          ),
          _RegStep('Valid ID', _idsDone, _idUploads()),
          _RegStep(
            'Password',
            _ok(['password', 'confirm_password']) && consent && acceptedTerms,
            _passwordFields(context),
          ),
        ];

  List<Widget> _personFields() => [
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
  ];

  /// Any valid ID with a photo (not only a government ID). Required for
  /// donors (Door to Door pickup safety) and for an organization's contact
  /// person.
  List<Widget> _idUploads() => [
    _upload(
      'Valid ID (front)',
      'id_front',
      idFront,
      (f) => idFront = f,
      helper:
          'Any valid ID with your photo and name, e.g. a national ID, '
          'driver\'s license, passport, postal, school or company ID.',
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
  ];

  List<Widget> _passwordFields(BuildContext context) => [
    _text('password', 'Password', password: true),
    _passwordRules(context),
    _text('confirm_password', 'Confirm password', password: true),
    _consent(context),
    _terms(context),
  ];

  void _goTo(int i) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _step = i);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final steps = _steps(context);
    final at = _step.clamp(0, steps.length - 1);
    final last = at == steps.length - 1;
    final done = steps[at].done;
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
        child: SingleChildScrollView(
          controller: _scroll,
          padding: Space.page,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.org
                    ? 'Your organization account is active as soon as you '
                          'register, and you\'ll go straight to your '
                          'dashboard. The Administrator may review your '
                          'details afterward.'
                    : 'Your account is active right away. The Administrator '
                          'may review your ID later.',
                style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
              Gaps.v16,
              _StepBar(step: at, titles: [for (final s in steps) s.title]),
              SectionHeader(steps[at].title),
              for (var i = 0; i < steps.length; i++)
                Offstage(
                  offstage: i != at,
                  child: TickerMode(
                    enabled: i == at,
                    child: ExcludeFocus(
                      excluding: i != at,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: steps[i].children,
                      ),
                    ),
                  ),
                ),
              Row(
                children: [
                  if (at > 0) ...[
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const ValueKey('register-back'),
                        onPressed: busy ? null : () => _goTo(at - 1),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ),
                        icon: const Icon(Icons.arrow_back),
                        label: const Text('Back'),
                      ),
                    ),
                    Gaps.h12,
                  ],
                  Expanded(
                    flex: 2,
                    child: last
                        ? AppButton(
                            widget.org ? 'Submit registration' : 'Create account',
                            key: const ValueKey('register-button'),
                            onPressed: _valid && !busy ? _submit : null,
                            loading: busy,
                            expand: true,
                          )
                        : AppButton(
                            'Next',
                            key: const ValueKey('register-next'),
                            icon: Icons.arrow_forward,
                            onPressed: done ? () => _goTo(at + 1) : null,
                            expand: true,
                          ),
                  ),
                ],
              ),
              if (!done) ...[
                Gaps.v8,
                Text(
                  last
                      ? 'Fill in every field and tick both boxes to finish.'
                      : 'Fill in every required field on this step to '
                            'continue.',
                  key: const ValueKey('register-step-hint'),
                  style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
              Gaps.v24,
            ],
          ),
        ),
      ),
    );
  }
}

class _RegStep {
  final String title;

  /// True when every required field of this step is filled in and valid.
  final bool done;
  final List<Widget> children;
  const _RegStep(this.title, this.done, this.children);
}

/// "Step 2 of 3" with a bar and the step names. Display only: the names
/// can't be tapped, so a step can't be skipped.
class _StepBar extends StatelessWidget {
  final int step;
  final List<String> titles;
  const _StepBar({required this.step, required this.titles});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final n = titles.length;
    return Semantics(
      liveRegion: true,
      label: 'Step ${step + 1} of $n: ${titles[step]}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Step ${step + 1} of $n',
            key: const ValueKey('register-step-label'),
            style: t.labelLarge?.copyWith(color: cs.primary),
          ),
          Gaps.v8,
          LinearProgressIndicator(
            value: (step + 1) / n,
            minHeight: 4,
            backgroundColor: cs.surfaceContainerHighest,
          ),
          Gaps.v8,
          Text(
            [
              for (var i = 0; i < n; i++)
                '${i < step ? '✓' : '${i + 1}.'} ${titles[i]}',
            ].join('   '),
            style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
