/// Shared phone rule: a Philippine mobile number, saved as 09XXXXXXXXX.
class PhonePolicy {
  static const String hint = 'a mobile number like 09171234567';

  /// [raw] as 09XXXXXXXXX (spaces, dashes and +63 allowed), or null if it isn't one.
  static String? normalize(String raw) {
    var s = raw.replaceAll(RegExp(r'[\s\-()]'), '');
    if (s.startsWith('+63')) s = '0${s.substring(3)}';
    if (s.startsWith('63') && s.length == 12) s = '0${s.substring(2)}';
    return RegExp(r'^09\d{9}$').hasMatch(s) ? s : null;
  }

  /// Returns an error message, or null when [raw] is acceptable.
  static String? check(String raw) => normalize(raw) == null ? 'Enter $hint.' : null;
}
