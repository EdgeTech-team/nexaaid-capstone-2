import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'validators.dart';
import 'widgets.dart';

// NexaAid palette (deep teal + warm donation amber)
const _bgTop = Color(0xFF062B2E);
const _bgBottom = Color(0xFF0B4A47);
const _teal = Color(0xFF14A38F);
const _tealLight = Color(0xFF5EEAD4);
const _amber = Color(0xFFFFB347);
const _fieldFill = Color(0x1AFFFFFF);

/// UC-D1 (donor) and UC-R1 (relief organization) registration.
/// Donors and organizations choose their own password.
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
  bool _showPw = false;
  bool _showConfirm = false;

  TextEditingController _c(String k) =>
      c.putIfAbsent(k, TextEditingController.new);

  @override
  void dispose() {
    for (final x in c.values) {
      x.dispose();
    }

    super.dispose();
  }

  OutlineInputBorder _border(Color color, {double w = 1.2}) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(30),
      borderSide: BorderSide(color: color, width: w),
    );
  }

  Widget _field(
    String key,
    String label,
    IconData icon,
    String? Function(String?) validator, {
    TextInputType? type,
    int maxLength = 150,
    List<TextInputFormatter>? formatters,
    TextCapitalization caps = TextCapitalization.none,
    String? hint,
    bool obscure = false,
    Widget? suffix,
    void Function(String)? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextFormField(
        controller: _c(key),
        keyboardType: type,
        maxLength: maxLength,
        inputFormatters: formatters,
        textCapitalization: caps,
        obscureText: obscure,
        onChanged: onChanged,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        style: const TextStyle(color: Colors.white),
        cursorColor: _tealLight,
        validator: validator,
        decoration: InputDecoration(
          counterText: '',
          labelText: label,
          hintText: hint,
          labelStyle: const TextStyle(color: Colors.white70),
          hintStyle: const TextStyle(color: Colors.white38),
          floatingLabelStyle: const TextStyle(color: _tealLight),
          prefixIcon: Icon(icon, color: Colors.white70, size: 20),
          suffixIcon: suffix,
          filled: true,
          fillColor: _fieldFill,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 16,
          ),
          enabledBorder: _border(Colors.white38),
          focusedBorder: _border(_tealLight, w: 1.8),
          errorBorder: _border(const Color(0xFFFF8A80)),
          focusedErrorBorder: _border(const Color(0xFFFF8A80), w: 1.8),
          errorStyle: const TextStyle(color: Color(0xFFFFAB91)),
          errorMaxLines: 2,
        ),
      ),
    );
  }

  Widget _rule(String text, bool ok) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 16,
            color: ok ? _tealLight : Colors.white38,
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              fontSize: 12.5,
              color: ok ? _tealLight : Colors.white60,
            ),
          ),
        ],
      ),
    );
  }

  Widget _passwordChecklist() {
    final p = _c('password').text;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16, left: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _rule('8-64 characters', p.length >= 8 && p.length <= 64),
          _rule('One uppercase letter', RegExp(r'[A-Z]').hasMatch(p)),
          _rule('One lowercase letter', RegExp(r'[a-z]').hasMatch(p)),
          _rule('One number', RegExp(r'\d').hasMatch(p)),
          _rule('One special character', RegExp(r'[^A-Za-z0-9]').hasMatch(p)),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    // Validate all fields first.
    if (!_form.currentState!.validate()) {
      return;
    }

    setState(() {
      busy = true;
    });

    String v(String k) => Validators.squash(_c(k).text);

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
                'contact_email': _c('email').text.trim(),
                'contact_number': _c('contact_number').text.trim(),
                'password': _c('password').text,
                'confirm_password': _c('confirm_password').text,
              },
            )
          : api.post(
              '/auth/register/donor',
              body: {
                'first_name': v('first_name'),
                'last_name': v('last_name'),
                'email': _c('email').text.trim(),
                'contact_number': _c('contact_number').text.trim(),
                'id_document_url': v('id_doc').isEmpty ? null : v('id_doc'),
                'password': _c('password').text,
                'confirm_password': _c('confirm_password').text,
              },
            ),
      success: widget.org
          ? 'Registration submitted. You can log in once the Administrator approves your organization.'
          : 'Account created. You can now log in.',
    );

    if (!mounted) {
      return;
    }

    setState(() {
      busy = false;
    });

    if (r.ok) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final noDigits = [FilteringTextInputFormatter.deny(RegExp(r'[0-9]'))];

    final phoneFmt = [FilteringTextInputFormatter.digitsOnly];

    return Scaffold(
      resizeToAvoidBottomInset: true,

      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_bgTop, _bgBottom],
          ),
        ),

        child: Stack(
          children: [
            // Bottom wave decoration.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 170,
              child: CustomPaint(painter: _WavePainter()),
            ),

            SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),

                  child: Form(
                    key: _form,

                    // Scrollbar allows the user to see that
                    // there is more content below.
                    child: Scrollbar(
                      thumbVisibility: true,

                      child: ListView(
                        // Makes the screen scroll even when
                        // content is close to the viewport size.
                        physics: const AlwaysScrollableScrollPhysics(),

                        // Extra bottom padding prevents the
                        // button/login area from being hidden
                        // behind the wave decoration.
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 120),

                        // Allows the keyboard to be dismissed
                        // by dragging the form upward.
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,

                        children: [
                          // --------------------------------------------------
                          // TOP BAR
                          // --------------------------------------------------

                          Row(
                            children: [
                              TextButton.icon(
                                onPressed: busy
                                    ? null
                                    : () => Navigator.pop(context),
                                icon: const Icon(
                                  Icons.chevron_left,
                                  color: Colors.white70,
                                ),
                                label: const Text(
                                  'Back',
                                  style: TextStyle(color: Colors.white70),
                                ),
                              ),

                              const Spacer(),

                              const _Logo(),
                            ],
                          ),

                          const SizedBox(height: 12),

                          // --------------------------------------------------
                          // TITLE
                          // --------------------------------------------------
                          Text(
                            widget.org
                                ? 'Register your\norganization'
                                : 'Join NexaAid!',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 30,
                              fontWeight: FontWeight.w700,
                              height: 1.2,
                            ),
                          ),

                          const SizedBox(height: 6),

                          const Text(
                            'Give help where it is needed most',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: _tealLight, fontSize: 14),
                          ),

                          const SizedBox(height: 28),

                          // --------------------------------------------------
                          // ORGANIZATION REGISTRATION
                          // --------------------------------------------------
                          if (widget.org) ...[
                            _field(
                              'org_name',
                              'Organization name',
                              Icons.business_outlined,
                              Validators.orgName,
                            ),

                            _field(
                              'organization_type',
                              'Organization type (e.g. NGO)',
                              Icons.category_outlined,
                              (v) => Validators.text(
                                v,
                                'Organization type',
                                2,
                                100,
                              ),
                              maxLength: 100,
                            ),

                            _field(
                              'address',
                              'Address',
                              Icons.location_on_outlined,
                              (v) => Validators.text(v, 'Address', 10, 300),
                              maxLength: 300,
                            ),

                            _field(
                              'contact_person',
                              'Contact person',
                              Icons.person_outline,
                              (v) => Validators.personName(
                                v,
                                label: 'Contact person',
                              ),
                              maxLength: 50,
                              formatters: noDigits,
                              caps: TextCapitalization.words,
                            ),

                            _field(
                              'registration_no',
                              'Registration number',
                              Icons.badge_outlined,
                              Validators.registrationNo,
                              maxLength: 100,
                            ),

                            _field(
                              'doc',
                              'Legitimacy document link (optional)',
                              Icons.link,
                              Validators.optionalUrl,
                              type: TextInputType.url,
                              maxLength: 500,
                            ),
                          ]
                          // --------------------------------------------------
                          // DONOR REGISTRATION
                          // --------------------------------------------------
                          else ...[
                            _field(
                              'first_name',
                              'First name',
                              Icons.person_outline,
                              (v) =>
                                  Validators.personName(v, label: 'First name'),
                              maxLength: 50,
                              formatters: noDigits,
                              caps: TextCapitalization.words,
                            ),

                            _field(
                              'last_name',
                              'Last name',
                              Icons.person_outline,
                              (v) =>
                                  Validators.personName(v, label: 'Last name'),
                              maxLength: 50,
                              formatters: noDigits,
                              caps: TextCapitalization.words,
                            ),

                            _field(
                              'id_doc',
                              'Valid ID (link to photo or scan)',
                              Icons.badge_outlined,
                              Validators.requiredUrl,
                              type: TextInputType.url,
                              maxLength: 500,
                            ),
                          ],

                          // --------------------------------------------------
                          // EMAIL
                          // --------------------------------------------------
                          _field(
                            'email',
                            'Email',
                            Icons.mail_outline,
                            Validators.email,
                            type: TextInputType.emailAddress,
                          ),

                          // --------------------------------------------------
                          // CONTACT NUMBER
                          // --------------------------------------------------
                          _field(
                            'contact_number',
                            'Contact number',
                            Icons.phone_outlined,
                            Validators.phMobile,
                            type: TextInputType.phone,
                            maxLength: 11,
                            formatters: phoneFmt,
                            hint: '09171234567',
                          ),

                          // --------------------------------------------------
                          // PASSWORD
                          // --------------------------------------------------
                          _field(
                            'password',
                            'Password',
                            Icons.lock_outline,
                            Validators.newPassword,
                            maxLength: 64,
                            obscure: !_showPw,
                            onChanged: (_) {
                              setState(() {});
                            },
                            suffix: IconButton(
                              icon: Icon(
                                _showPw
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                                color: Colors.white70,
                                size: 20,
                              ),
                              onPressed: () {
                                setState(() {
                                  _showPw = !_showPw;
                                });
                              },
                            ),
                          ),

                          // Password requirements.
                          _passwordChecklist(),

                          // --------------------------------------------------
                          // CONFIRM PASSWORD
                          // --------------------------------------------------
                          _field(
                            'confirm_password',
                            'Confirm password',
                            Icons.lock_reset,
                            (v) => Validators.confirmPassword(
                              v,
                              _c('password').text,
                            ),
                            maxLength: 64,
                            obscure: !_showConfirm,
                            suffix: IconButton(
                              icon: Icon(
                                _showConfirm
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                                color: Colors.white70,
                                size: 20,
                              ),
                              onPressed: () {
                                setState(() {
                                  _showConfirm = !_showConfirm;
                                });
                              },
                            ),
                          ),

                          const SizedBox(height: 4),

                          // --------------------------------------------------
                          // CREATE ACCOUNT BUTTON
                          // --------------------------------------------------
                          SizedBox(
                            height: 52,
                            child: FilledButton(
                              onPressed: busy ? null : _submit,

                              style: FilledButton.styleFrom(
                                backgroundColor: _teal,
                                foregroundColor: Colors.white,
                                shape: const StadiumBorder(),
                                elevation: 6,
                                shadowColor: _teal,
                              ),

                              child: busy
                                  ? const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.5,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Text(
                                      'Create account',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                            ),
                          ),

                          const SizedBox(height: 16),

                          // --------------------------------------------------
                          // LOGIN LINK
                          // --------------------------------------------------
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Text(
                                'Already a member? ',
                                style: TextStyle(color: Colors.white70),
                              ),

                              GestureDetector(
                                onTap: busy
                                    ? null
                                    : () => Navigator.pop(context),
                                child: const Text(
                                  'Log in',
                                  style: TextStyle(
                                    color: _amber,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),

                          // Extra space at the very bottom.
                          // This lets the user scroll the last
                          // section comfortably above the wave.
                          const SizedBox(height: 40),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// NEXAAID LOGO
// ============================================================================

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'NexaAid',
          style: TextStyle(
            color: _tealLight,
            fontWeight: FontWeight.w700,
            fontSize: 16,
          ),
        ),

        const SizedBox(width: 8),

        Container(
          width: 40,
          height: 40,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(colors: [_amber, Color(0xFFFF8A4C)]),
          ),

          child: const Icon(
            Icons.volunteer_activism,
            color: Colors.white,
            size: 22,
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// BACKGROUND WAVE
// ============================================================================

class _WavePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    Path wave(double base, double amp, double phase) {
      final p = Path()
        ..moveTo(0, size.height)
        ..lineTo(0, base);

      for (double x = 0; x <= size.width; x += 4) {
        final y =
            base +
            amp *
                (1 - (((x / size.width) * 2 + phase) % 2 - 1).abs() * 2).abs();

        p.lineTo(x, y);
      }

      p
        ..lineTo(size.width, size.height)
        ..close();

      return p;
    }

    canvas.drawPath(
      wave(size.height * 0.45, 22, 0.2),
      Paint()..color = const Color(0x3314A38F),
    );

    canvas.drawPath(
      wave(size.height * 0.65, 18, 0.7),
      Paint()..color = const Color(0x5514A38F),
    );

    canvas.drawPath(
      wave(size.height * 0.85, 14, 1.2),
      Paint()..color = const Color(0x8814A38F),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return false;
  }
}
