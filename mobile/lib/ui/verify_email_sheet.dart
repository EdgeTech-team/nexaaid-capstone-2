// NF-006 (D4): verify the account email once, for Door to Door pickups.
//
// Registration still signs in at once. A Door to Door donation from an
// account whose email is not verified yet is saved but stays off the CSWS
// pickup map until the donor enters the 6-digit code we email
// (POST /auth/verify-email/send and /confirm). After that, every Door to
// Door donation goes straight through. Drop Off never needs it.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'widgets.dart';

const verifyEmailBannerText = 'Verify your email to request pickups';
const emailHoldText =
    'Check your email. Enter the code to send this pickup to CSWS.';

/// Sends a code and asks for it. True once the email is verified.
Future<bool> showVerifyEmailSheet(BuildContext context) async {
  final done = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _VerifyEmailSheet(),
  );
  return done == true;
}

class _VerifyEmailSheet extends StatefulWidget {
  const _VerifyEmailSheet();

  @override
  State<_VerifyEmailSheet> createState() => _VerifyEmailSheetState();
}

class _VerifyEmailSheetState extends State<_VerifyEmailSheet> {
  final _code = TextEditingController();
  bool _sending = false;
  bool _checking = false;
  String? _sentTo;
  String? _error;

  @override
  void initState() {
    super.initState();
    _send();
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    final r = await api.post('/auth/verify-email/send', body: const {});
    if (!mounted) return;
    setState(() => _sending = false);
    if (r.ok && r.json is Map && r.json['email_verified'] == true) {
      Navigator.pop(context, true); // already verified
      return;
    }
    setState(() {
      if (r.ok) {
        _sentTo =
            '${r.json['detail'] ?? 'We sent a 6-digit code to your email.'}';
      } else {
        _error = r.status == 0 ? 'Cannot reach the server' : r.errorText;
      }
    });
  }

  Future<void> _confirm() async {
    final code = _code.text.trim();
    if (code.length != 6) {
      setState(() => _error = 'Enter the 6-digit code from the email.');
      return;
    }
    setState(() {
      _checking = true;
      _error = null;
    });
    final r = await api.post(
      '/auth/verify-email/confirm',
      body: {'code': code},
    );
    if (!mounted) return;
    setState(() => _checking = false);
    if (r.ok) {
      AppToast.success(
        context,
        'Email verified. Your pickups are now with CSWS.',
      );
      Navigator.pop(context, true);
      return;
    }
    setState(
      () => _error = r.status == 0 ? 'Cannot reach the server' : r.errorText,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        left: Space.lg,
        right: Space.lg,
        bottom: MediaQuery.viewInsetsOf(context).bottom + Space.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Verify your email', style: t.titleLarge),
          Gaps.v4,
          Text(
            'You only do this once. Then CSWS can pick up your Door to Door '
            'donations. Drop Off never needs it.',
            style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          Gaps.v12,
          if (_sending)
            const LinearProgressIndicator()
          else if (_sentTo != null)
            Text(_sentTo!, style: t.bodyMedium),
          Gaps.v12,
          TextField(
            key: const ValueKey('verify-code'),
            controller: _code,
            keyboardType: TextInputType.number,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: '6-digit code',
              prefixIcon: const Icon(Icons.mark_email_read_outlined),
              errorText: _error,
            ),
            onSubmitted: (_) => _confirm(),
          ),
          Gaps.v8,
          AppButton(
            'Verify email',
            icon: Icons.verified_outlined,
            expand: true,
            loading: _checking,
            onPressed: _checking ? null : _confirm,
          ),
          TextButton(
            onPressed: _sending ? null : _send,
            child: const Text('Send a new code'),
          ),
        ],
      ),
    );
  }
}

/// "Verify your email to request pickups" on the donor and organization
/// dashboards, until the email is verified (GET /auth/me email_verified).
class VerifyEmailBanner extends StatefulWidget {
  const VerifyEmailBanner({super.key});

  @override
  State<VerifyEmailBanner> createState() => _VerifyEmailBannerState();
}

class _VerifyEmailBannerState extends State<VerifyEmailBanner> {
  bool _show = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    if (!api.loggedIn) return;
    final r = await api.get('/auth/me');
    if (!mounted) return;
    setState(
      () => _show = r.ok && r.json is Map && r.json['email_verified'] == false,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_show) return const SizedBox.shrink();
    final t = Theme.of(context).textTheme;
    final caution = StatusColors.of('On Hold', Theme.of(context).brightness);
    return Container(
      margin: const EdgeInsets.only(bottom: Space.md),
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: caution.bg,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(
        children: [
          Icon(Icons.mark_email_unread_outlined, color: caution.fg),
          Gaps.h12,
          Expanded(
            child: Text(
              verifyEmailBannerText,
              style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            onPressed: () async {
              if (await showVerifyEmailSheet(context)) {
                if (mounted) setState(() => _show = false);
              }
            },
            child: const Text('Verify'),
          ),
        ],
      ),
    );
  }
}

/// On a donation waiting for the code (awaiting_email from the server).
class EmailHoldNote extends StatelessWidget {
  final VoidCallback? onVerified;
  const EmailHoldNote({super.key, this.onVerified});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final caution = StatusColors.of('On Hold', Theme.of(context).brightness);
    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: caution.bg,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.mark_email_unread_outlined, color: caution.fg),
              Gaps.h12,
              Expanded(child: Text(emailHoldText, style: t.bodyMedium)),
            ],
          ),
          Gaps.v8,
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: () async {
                if (await showVerifyEmailSheet(context)) onVerified?.call();
              },
              icon: const Icon(Icons.pin_outlined, size: 20),
              label: const Text('Enter code'),
            ),
          ),
        ],
      ),
    );
  }
}
