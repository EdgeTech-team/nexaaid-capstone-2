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

/// Capitalizes only the first character of the whole text (e.g. organization
/// name). Words after the first are kept as typed, so "of", "and" and
/// acronyms like "NGO" are not changed.
class CapitalizeFirstLetterFormatter extends TextInputFormatter {
  const CapitalizeFirstLetterFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final t = newValue.text;
    if (t.isEmpty) return newValue;
    final fixed = t[0].toUpperCase() + t.substring(1);
    // Same length as before, so the cursor and selection stay where they are.
    return fixed == t ? newValue : newValue.copyWith(text: fixed);
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

/// Organization name: capitalize only the first letter.
final orgNameFormatters = <TextInputFormatter>[
  CapitalizeFirstLetterFormatter(),
];
