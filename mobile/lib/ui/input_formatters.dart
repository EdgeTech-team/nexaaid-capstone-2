import 'package:flutter/services.dart';

/// Capitalizes the first letter of every word while the user types
/// (adviser item 2). TextCapitalization.words only changes the keyboard,
/// and users can still type lower case, so the text itself is fixed here.
/// The rest of each word is kept as typed ("McDonald" stays). The backend
/// does the same in core/names.py.
class CapitalizeWordsFormatter extends TextInputFormatter {
  const CapitalizeWordsFormatter();

  static final _wordStart = RegExp(r"(^|[\s\-'.])(\p{L})", unicode: true);

  static String apply(String text) =>
      text.replaceAllMapped(_wordStart, (m) => '${m[1]}${m[2]!.toUpperCase()}');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = apply(newValue.text);
    // Same length as before, so the cursor and selection stay where they are.
    return newValue.copyWith(text: text);
  }
}

/// Philippine mobile number: digits only, at most 11 (09XXXXXXXXX).
/// Typing a 12th digit or a letter does nothing.
final phoneFormatters = <TextInputFormatter>[
  FilteringTextInputFormatter.digitsOnly,
  LengthLimitingTextInputFormatter(11),
];

/// Name fields: capitalize each word, at most 50 characters (users table).
final nameFormatters = <TextInputFormatter>[
  CapitalizeWordsFormatter(),
  LengthLimitingTextInputFormatter(50),
];
