import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Quick actions CSWS uses during Door to Door pickups: call or text the
/// donor, copy details, and open directions in Google Maps. Shared by the
/// pickup board and the donation sheet so they behave the same everywhere.

/// "0917 123 4567" / "+63 917..." -> "+639171234567" for the phone dialer.
String dialable(String raw) {
  final digits = raw.replaceAll(RegExp(r'[^0-9+]'), '');
  if (digits.startsWith('09') && digits.length == 11) {
    return '+63${digits.substring(1)}';
  }
  if (digits.startsWith('63') && digits.length == 12) return '+$digits';
  return digits;
}

/// "09171234567" -> "0917 123 4567" (easier to read aloud).
String prettyPhone(String raw) {
  final d = raw.replaceAll(RegExp(r'[^0-9]'), '');
  final local = d.startsWith('63') && d.length == 12 ? '0${d.substring(2)}' : d;
  if (local.length == 11) {
    return '${local.substring(0, 4)} ${local.substring(4, 7)} ${local.substring(7)}';
  }
  return raw;
}

Future<void> _launch(BuildContext context, Uri uri, String failMessage) async {
  var opened = false;
  try {
    opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {}
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(failMessage)));
  }
}

Future<void> callNumber(BuildContext context, String phone) => _launch(
  context,
  Uri(scheme: 'tel', path: dialable(phone)),
  'Could not open the phone app. Number: ${prettyPhone(phone)}',
);

Future<void> textNumber(
  BuildContext context,
  String phone, {
  String? message,
}) => _launch(
  context,
  Uri(
    scheme: 'sms',
    path: dialable(phone),
    queryParameters: message == null ? null : {'body': message},
  ),
  'Could not open messages. Number: ${prettyPhone(phone)}',
);

Future<void> copyText(BuildContext context, String text, String what) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$what copied')));
  }
}

/// Directions in Google Maps. Uses the exact pin when the donor picked an
/// address suggestion, otherwise searches the typed address, so every
/// pickup can be navigated to.
Future<void> openNavigation(
  BuildContext context, {
  double? lat,
  double? lng,
  String? address,
}) {
  final destination = lat != null && lng != null
      ? '$lat,$lng'
      : (address ?? '').trim();
  return _launch(
    context,
    Uri.https('www.google.com', '/maps/dir/', {
      'api': '1',
      'destination': destination,
    }),
    'Could not open a maps app',
  );
}

/// Phone number with Call, Text and Copy buttons.
class ContactButtons extends StatelessWidget {
  final String phone;
  final String? smsMessage;
  const ContactButtons({super.key, required this.phone, this.smsMessage});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      runSpacing: 4,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Text(prettyPhone(phone), style: t.titleSmall),
        ),
        FilledButton.tonalIcon(
          onPressed: () => callNumber(context, phone),
          icon: const Icon(Icons.call, size: 18),
          label: const Text('Call'),
        ),
        OutlinedButton.icon(
          onPressed: () => textNumber(context, phone, message: smsMessage),
          icon: const Icon(Icons.sms_outlined, size: 18),
          label: const Text('Text'),
        ),
        IconButton(
          tooltip: 'Copy number',
          onPressed: () => copyText(context, phone, 'Number'),
          icon: const Icon(Icons.copy, size: 18),
        ),
      ],
    );
  }
}
