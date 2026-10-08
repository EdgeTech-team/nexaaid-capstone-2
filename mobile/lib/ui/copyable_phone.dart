import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Copies [number] to the clipboard and shows a short confirmation.
/// Use this anywhere a phone number used to open the dialer or SMS app.
Future<void> copyPhoneNumber(BuildContext context, String number) async {
  final value = number.trim();
  if (value.isEmpty) return;
  await Clipboard.setData(ClipboardData(text: value));
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text('Copied $value'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
}

/// Shows a phone number as plain text with a copy icon.
/// Tapping the number or the icon copies it. It never calls or texts.
class CopyablePhone extends StatelessWidget {
  const CopyablePhone({
    super.key,
    required this.number,
    this.style,
    this.iconSize = 18,
    this.emptyText = '—',
  });

  final String? number;
  final TextStyle? style;
  final double iconSize;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final value = (number ?? '').trim();
    if (value.isEmpty) {
      return Text(emptyText, style: style);
    }
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => copyPhoneNumber(context, value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: Text(value, style: style)),
            const SizedBox(width: 6),
            Icon(Icons.copy_rounded, size: iconSize),
          ],
        ),
      ),
    );
  }
}
