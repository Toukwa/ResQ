/// Shared password rule: at least 8 characters with a lowercase letter and a number.
class PasswordPolicy {
  static const String hint = 'at least 8 characters, including a lowercase letter and a number';

  /// Returns an error message, or null when [password] is acceptable.
  static String? check(String password) {
    if (password.length < 8 ||
        !RegExp(r'[a-z]').hasMatch(password) ||
        !RegExp(r'[0-9]').hasMatch(password)) {
      return 'Password must be $hint.';
    }
    return null;
  }
}
