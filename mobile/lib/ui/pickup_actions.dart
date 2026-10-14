import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Quick actions CSWS uses during Door to Door pickups: copy the donor's
/// number and details, and open directions in Google Maps. Shared by the
/// pickup board and the donation sheet so they behave the same everywhere.
///
/// Phone numbers are copy-only: the app never opens the dialer or the SMS app.

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

Future<void> copyText(BuildContext context, String text, String what) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('$what copied')));
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

/// Phone number that can only be copied. Tap the number or the copy icon.
/// [smsMessage] is kept so existing callers still compile; it is not used,
/// because the app no longer opens the SMS app.
class ContactButtons extends StatelessWidget {
  final String phone;
  final String? smsMessage;
  const ContactButtons({super.key, required this.phone, this.smsMessage});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final value = phone.trim();
    if (value.isEmpty) return const SizedBox.shrink();
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => copyText(context, value, 'Number'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: Text(prettyPhone(value), style: t.titleSmall)),
            const SizedBox(width: 6),
            const Icon(Icons.copy, size: 18),
          ],
        ),
      ),
    );
  }
}
