/// Client-side rules. They mirror the backend (core/validators.py) so the app
/// and the API agree. Each returns null when valid, or the error text.
class Validators {
  static const _l = 'A-Za-zÀ-ÖØ-öø-ÿ';

  static final _nameRe = RegExp("^[$_l]+(?:(?:\\.\\s|[ '\\-])[$_l]+)*\\.?\$");
  static final _orgNameRe = RegExp("^[${_l}0-9][${_l}0-9 &.,'()\\-/]{1,149}\$");
  static final _emailRe = RegExp(
    r'^[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}$',
  );
  static final _phRe = RegExp(r'^09\d{9}$'); // 11 digits, PH mobile
  static final _regNoRe = RegExp(r'^[A-Za-z0-9][A-Za-z0-9\-/ ]{3,99}$');
  static final _repeatRe = RegExp(r'(.)\1{3,}', caseSensitive: false);

  static String squash(String v) => v.trim().replaceAll(RegExp(r'\s+'), ' ');

    /// D2 rule plus concern 1.1: 8-64 characters, no spaces, at least one
  /// capital letter and one number. Keep this in sync with
  /// validate_password_strength in backend/app/core/passwords.py.
  static String? newPassword(String? v) {
    final s = v ?? '';
    if (s.isEmpty) return 'Password is required';
    if (s.length < 8 || s.length > 64) return 'Use 8-64 characters';
    if (s.contains(' ')) return 'No spaces allowed';
    if (!RegExp(r'[A-Z]').hasMatch(s)) return 'Add a capital letter';
    if (!RegExp(r'\d').hasMatch(s)) return 'Add a number';
    return null;
  }

  static String? confirmPassword(String? v, String original) {
    if ((v ?? '').isEmpty) return 'Confirm your password';
    if (v != original) return 'Passwords do not match';
    return null;
  }

  static String? personName(String? v, {String label = 'Name'}) {
    final s = squash(v ?? '');
    if (s.isEmpty) return '$label is required';
    if (s.length < 2 || s.length > 50) return '$label must be 2-50 characters';
    if (!_nameRe.hasMatch(s)) {
      return 'Letters, spaces, hyphens, apostrophes and periods only';
    }
    if (_repeatRe.hasMatch(s)) return '$label looks invalid';
    return null;
  }

  static String? orgName(String? v) {
    final s = squash(v ?? '');
    if (s.isEmpty) return 'Organization name is required';
    if (!_orgNameRe.hasMatch(s)) {
      return '2-150 characters: letters, numbers and & . , \' ( ) - / only';
    }
    return null;
  }

  static String? text(String? v, String label, int min, int max) {
    final s = squash(v ?? '');
    if (s.isEmpty) return '$label is required';
    if (s.length < min || s.length > max) {
      return '$label must be $min-$max characters';
    }
    return null;
  }

  static String? registrationNo(String? v) {
    final s = squash(v ?? '');
    if (s.isEmpty) return 'Registration number is required';
    if (!_regNoRe.hasMatch(s)) {
      return '4-100 characters: letters, numbers, spaces, - and / only';
    }
    return null;
  }

  static String? email(String? v) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return 'Email is required';
    if (s.length > 150) return 'Email is too long';
    if (!_emailRe.hasMatch(s)) {
      return 'Enter a valid email, e.g. name@example.com';
    }
    return null;
  }

  static String? phMobile(String? v) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return 'Contact number is required';
    if (!_phRe.hasMatch(s)) return 'Must be 11 digits, e.g. 09171234567';
    return null;
  }

  static String? optionalUrl(String? v) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return null;
    final u = Uri.tryParse(s);
    if (u == null ||
        !(u.scheme == 'http' || u.scheme == 'https') ||
        !u.host.contains('.') ||
        s.length > 500) {
      return 'Enter a valid link starting with http:// or https://';
    }
    return null;
  }

  static String? requiredUrl(String? v) {
    if ((v ?? '').trim().isEmpty) return 'Valid ID link is required';
    return optionalUrl(v);
  }
}
