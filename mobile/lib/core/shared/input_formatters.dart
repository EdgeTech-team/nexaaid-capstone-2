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

/// Capitalizes the first letter of every word in an organization name. Words
/// are split on spaces only, so "St. Mary's" is not turned into "St. Mary'S".
/// The rest of each word is kept as typed ("NGO" stays). The backend does the
/// same in core/names.py (capitalize_org_words).
class CapitalizeOrgWordsFormatter extends TextInputFormatter {
  const CapitalizeOrgWordsFormatter();

  static final _wordStart = RegExp(r"(^|\s)(\p{L})", unicode: true);

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text.replaceAllMapped(
      _wordStart,
      (m) => '${m[1]}${m[2]!.toUpperCase()}',
    );
    // Same length as before, so the cursor and selection stay where they are.
    return text == newValue.text ? newValue : newValue.copyWith(text: text);
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

/// Organization name: capitalize the first letter of every word.
final orgNameFormatters = <TextInputFormatter>[CapitalizeOrgWordsFormatter()];

/// Peso amounts (problema_napud 4.1): digits only, shown with commas while
/// typing ("12500" -> "12,500"). At most 8 digits: physical_donations
/// .estimated_value is NUMERIC(10, 2). Read the number back with
/// [ThousandsFormatter.parse].
class ThousandsFormatter extends TextInputFormatter {
  const ThousandsFormatter({this.maxDigits = 8});
  final int maxDigits;

  static final _nonDigit = RegExp(r'[^0-9]');

  /// "12500" -> "12,500"
  static String format(String digits) {
    final d = digits
        .replaceAll(_nonDigit, '')
        .replaceFirst(RegExp(r'^0+(?=\d)'), '');
    final out = StringBuffer();
    for (var i = 0; i < d.length; i++) {
      if (i > 0 && (d.length - i) % 3 == 0) out.write(',');
      out.write(d[i]);
    }
    return out.toString();
  }

  /// "12,500" -> 12500, "" -> null
  static int? parse(String text) =>
      int.tryParse(text.replaceAll(_nonDigit, ''));

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(_nonDigit, '');
    if (digits.length > maxDigits) return oldValue;
    final text = format(digits);
    // Keep the cursor after the same number of digits as before.
    final before = newValue.selection.baseOffset < 0
        ? digits.length
        : newValue.text
              .substring(
                0,
                newValue.selection.baseOffset.clamp(0, newValue.text.length),
              )
              .replaceAll(_nonDigit, '')
              .length;
    var pos = 0;
    for (var seen = 0; pos < text.length && seen < before; pos++) {
      if (text[pos] != ',') seen++;
    }
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: pos),
    );
  }
}

/// "12500.00" / 12500 -> "PHP 12,500" (problema_napud 4.1), or null.
String? pesos(Object? value) {
  final n = value is num ? value : num.tryParse('${value ?? ''}');
  return n == null ? null : 'PHP ${ThousandsFormatter.format('${n.round()}')}';
}
