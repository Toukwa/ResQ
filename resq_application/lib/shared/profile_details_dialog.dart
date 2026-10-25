import 'resq_loader.dart';
import '../services/friendly_error.dart';
import 'package:flutter/material.dart';
import 'resq_dropdown.dart';

import '../services/firebase_services.dart';
import '../services/password_policy.dart';
import '../services/theme_service.dart';
import 'birthdate_picker.dart';
import 'iriga_address.dart';

/// Asks a citizen who signed up with Google (or an older account) for what the
/// sign-up form now requires: birthdate and barangay, and for Google accounts
/// a password so the same email works on the normal login.
/// Returns true once saved, false if the user chose to sign out instead.
Future<bool> showProfileDetailsDialog(
  BuildContext context, {
  required bool askDetails,
  required bool askPassword,
  required String email,
}) async {
  final saved = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ProfileDetailsDialog(askDetails: askDetails, askPassword: askPassword, email: email),
  );
  return saved == true;
}

class _ProfileDetailsDialog extends StatefulWidget {
  final bool askDetails;
  final bool askPassword;
  final String email;
  const _ProfileDetailsDialog({required this.askDetails, required this.askPassword, required this.email});

  @override
  State<_ProfileDetailsDialog> createState() => _ProfileDetailsDialogState();
}

class _ProfileDetailsDialogState extends State<_ProfileDetailsDialog> {
  static const _orange = Color(0xFFFF6B00);
  static const _red = Color(0xFFEF4444);
  DateTime? _birthdate;
  String? _barangay;
  String? _error;
  bool _busy = false;
  bool _obscure = true;
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    String? problem;
    if (widget.askDetails && (_birthdate == null || _barangay == null)) {
      problem = 'Please choose your birthdate and barangay.';
    } else if (widget.askPassword) {
      problem = PasswordPolicy.check(_password.text) ??
          (_password.text != _confirm.text ? 'Passwords do not match.' : null);
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
      if (widget.askPassword) await FirebaseService.setPassword(_password.text);
      if (widget.askDetails) {
        await FirebaseService.saveProfileDetails(
          birthdate: BirthdatePicker.format(_birthdate!),
          barangay: _barangay!,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = friendlyError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    final textDark = ts.isDark ? Colors.white : const Color(0xFF0F172A);
    final borderGrey = ts.isDark ? const Color(0xFF374151) : const Color(0xFFE2E8F0);
    const textGrey = Color(0xFF94A3B8);

    InputDecoration decor(String hint, IconData icon) => InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: textGrey),
          prefixIcon: Icon(icon, color: textGrey, size: 20),
          contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: borderGrey),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: _orange),
          ),
        );
    Widget label(String text) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(text, style: TextStyle(fontWeight: FontWeight.w600, color: textDark)),
        );

    return AlertDialog(
      backgroundColor: ts.isDark ? const Color(0xFF1F2937) : Colors.white,
      surfaceTintColor: Colors.transparent,
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      actionsPadding: const EdgeInsets.all(24),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _orange.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.badge_outlined, color: _orange, size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Complete Your Profile',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: textDark),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.askDetails
                  ? 'Responders need your birthdate and address. You only need to do this once.'
                  : 'Create a password so you can also log in with ${widget.email} on the login screen.',
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: ts.isDark ? Colors.grey.shade300 : const Color(0xFF475569),
              ),
            ),
            const SizedBox(height: 20),
            if (widget.askDetails) ...[
              label('Birthdate'),
              BirthdatePicker(
                enabled: !_busy,
                onChanged: (d) => setState(() => _birthdate = d),
                decoration: (hint) => decor(hint, Icons.cake_outlined)
                    .copyWith(prefixIcon: null, contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12)),
                textStyle: TextStyle(fontSize: 14, color: textDark),
                menuColor: ts.isDark ? const Color(0xFF1F2937) : Colors.white,
              ),
              const SizedBox(height: 16),
              label('Barangay'),
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
              const Text(IrigaAddress.city, style: TextStyle(fontSize: 12, color: textGrey)),
            ],
            if (widget.askDetails && widget.askPassword) const SizedBox(height: 20),
            if (widget.askPassword) ...[
              label('Create a Password'),
              Text(
                'So you can also log in with ${widget.email} and a password.',
                style: const TextStyle(fontSize: 12, color: textGrey),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _password,
                obscureText: _obscure,
                enabled: !_busy,
                style: TextStyle(color: textDark),
                decoration: decor('New password', Icons.lock_outline).copyWith(
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                        color: textGrey, size: 20),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _confirm,
                obscureText: _obscure,
                enabled: !_busy,
                style: TextStyle(color: textDark),
                decoration: decor('Confirm password', Icons.lock_outline),
              ),
              const SizedBox(height: 6),
              const Text('Use ${PasswordPolicy.hint}.', style: TextStyle(fontSize: 12, color: textGrey)),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.error_outline, size: 16, color: _red),
                  const SizedBox(width: 6),
                  Expanded(child: Text(_error!, style: const TextStyle(color: _red, fontSize: 13))),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : () => Navigator.pop(context, false),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  side: BorderSide(color: borderGrey),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: Text('Sign Out', style: TextStyle(color: textDark, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                onPressed: _busy ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _orange,
                  minimumSize: const Size.fromHeight(48),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: ResqLoader(color: Colors.white),
                      )
                    : const Text('Save', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
