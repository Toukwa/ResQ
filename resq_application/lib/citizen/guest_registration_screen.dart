import 'package:flutter/material.dart';
import '../shared/resq_dropdown.dart';

import '../services/firebase_services.dart';
import '../services/password_policy.dart';
import '../services/session_service.dart';
import '../shared/birthdate_picker.dart';
import '../shared/iriga_address.dart';
import '../shared/resq_toast.dart';
import '../services/theme_service.dart';

/// Shown to a Report Now guest once their report has ended. It turns the guest
/// account into a full one (same account, same reports) before they can go on.
/// Pops with true once registered.
class GuestRegistrationScreen extends StatefulWidget {
  final String userName;
  const GuestRegistrationScreen({super.key, required this.userName});

  @override
  State<GuestRegistrationScreen> createState() => _GuestRegistrationScreenState();
}

class _GuestRegistrationScreenState extends State<GuestRegistrationScreen> {
  static const _orange = Color(0xFFFF6B00);
  static const _red = Color(0xFFEF4444);
  Color get _textDark => ThemeService.instance.textPrimary;
  Color get _textGrey => ThemeService.instance.textSecondary;
  Color get _border => ThemeService.instance.borderColor;

  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  DateTime? _birthdate;
  String? _barangay;
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final email = _email.text.trim();
    String? problem;
    if (email.isEmpty || _birthdate == null || _barangay == null || _password.text.isEmpty) {
      problem = 'Please fill out all fields.';
    } else if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      problem = 'Please enter a valid email address.';
    } else {
      problem =
          PasswordPolicy.check(_password.text) ?? (_password.text != _confirm.text ? 'Passwords do not match.' : null);
    }
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await FirebaseService.upgradeGuest(
        email: email,
        password: _password.text,
        birthdate: BirthdatePicker.format(_birthdate!),
        barangay: _barangay!,
      );
      final session = await SessionService.getSession();
      await SessionService.saveSession(
        userId: (session?['id'] as int?) ?? 0,
        fullName: widget.userName,
        email: email.toLowerCase(),
        role: 'Citizen',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showResqSnackBar(
        const SnackBar(
          content: Text('Account created! You can now log in with your email.'),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e'.replaceFirst('HttpException: ', '').replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _logOut() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: ThemeService.instance.cardBackground,
        surfaceTintColor: Colors.transparent,
        titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
        contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
        actionsPadding: const EdgeInsets.all(24),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: _red.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.logout_rounded, color: _red, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Log out without registering?',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: _textDark),
              ),
            ),
          ],
        ),
        content: Text(
          "You'll be asked to finish this the next time you use Report Now on this phone.",
          style: TextStyle(fontSize: 13, color: ThemeService.instance.textSecondary, height: 1.4),
        ),
        actions: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(c, false),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    side: BorderSide(color: _border),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: Text('Stay', style: TextStyle(color: _textDark, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(c, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _red,
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: const Text('Log out', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (yes != true) return;
    await SessionService.clearSession();
    if (mounted) Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
  }

  InputDecoration _decor(String hint, IconData? icon) => InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(color: _textGrey),
    prefixIcon: icon == null ? null : Icon(icon, color: _textGrey, size: 20),
    filled: true,
    fillColor: ThemeService.instance.inputBackground,
    contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: _border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: _orange),
    ),
  );

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6, top: 12),
    child: Text(
      text,
      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _textDark),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // finishing sign-up (or logging out) is the only way on
      child: Scaffold(
        resizeToAvoidBottomInset: false, // keyboard covers the screen instead of pushing it up
        backgroundColor: ThemeService.instance.cardBackground,
        // Header stays on top; a shadow appears only once content scrolls under it
        appBar: AppBar(
          automaticallyImplyLeading: false,
          toolbarHeight: 72,
          titleSpacing: 24,
          backgroundColor: ThemeService.instance.cardBackground,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 4,
          shadowColor: Colors.black26,
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: _orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.how_to_reg_rounded, color: _orange),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Finish Your Registration',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: _textDark),
                    ),
                    Text('Your report has ended', style: TextStyle(fontSize: 12, color: _textGrey)),
                  ],
                ),
              ),
            ],
          ),
        ),
        body: SafeArea(
          top: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: ThemeService.instance.isDark ? const Color(0xFF431407) : const Color(0xFFFFF7ED),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: ThemeService.instance.isDark ? const Color(0xFF9A3412) : const Color(0xFFFED7AA)),
                        ),
                        child: Text(
                          'Thank you, ${widget.userName}. To keep using ResQ, finish setting up your account. '
                          'Your reports stay with it, and next time you can log in with your email.',
                          style: TextStyle(fontSize: 13, height: 1.4, color: ThemeService.instance.isDark ? const Color(0xFFFDBA74) : const Color(0xFF9A3412)),
                        ),
                      ),
                      _label('Email Address'),
                      TextField(
                        controller: _email,
                        enabled: !_busy,
                        keyboardType: TextInputType.emailAddress,
                        decoration: _decor('you@example.com', Icons.email_outlined),
                      ),
                      _label('Birthdate'),
                      BirthdatePicker(
                        enabled: !_busy,
                        onChanged: (d) => setState(() => _birthdate = d),
                        decoration: (hint) => _decor(hint, null),
                        textStyle: TextStyle(fontSize: 14, color: _textDark),
                        menuColor: ThemeService.instance.cardBackground,
                      ),
                      _label('Barangay'),
                      ResqSelect<String>(
          value: _barangay,
          hint: 'Select your barangay',
          icon: Icons.home_outlined,
          height: 48,
          enabled: !_busy,
          options: [for (final b in IrigaAddress.barangays) ResqOption(b, b, icon: Icons.location_on_outlined)],
          onChanged: (v) => setState(() => _barangay = v),
        ),
                      const SizedBox(height: 6),
                      Text(IrigaAddress.city, style: TextStyle(fontSize: 12, color: _textGrey)),
                      _label('Password'),
                      TextField(
                        controller: _password,
                        enabled: !_busy,
                        obscureText: _obscure,
                        decoration: _decor('••••••••', Icons.lock_outline).copyWith(
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                              color: _textGrey,
                              size: 20,
                            ),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                        ),
                      ),
                      _label('Confirm Password'),
                      TextField(
                        controller: _confirm,
                        enabled: !_busy,
                        obscureText: _obscure,
                        decoration: _decor('••••••••', Icons.lock_outline),
                      ),
                      const SizedBox(height: 6),
                      Text('Use ${PasswordPolicy.hint}.', style: TextStyle(fontSize: 12, color: _textGrey)),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.error_outline, size: 16, color: _red),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(_error!, style: const TextStyle(color: _red, fontSize: 13)),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 20),
                      ElevatedButton(
                        onPressed: _busy ? null : _save,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _orange,
                          minimumSize: const Size.fromHeight(50),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        child: _busy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                              )
                            : const Text(
                                'Create Account',
                                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                              ),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: _busy ? null : _logOut,
                        child: Text('Log out instead', style: TextStyle(color: _textGrey)),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
