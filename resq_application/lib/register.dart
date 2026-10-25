import 'shared/resq_loader.dart';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'shared/resq_dropdown.dart';
import 'auth_service.dart';
import 'services/theme_service.dart';
import 'shared/birthdate_picker.dart';
import 'shared/google_logo.dart';
import 'shared/iriga_address.dart';
import 'shared/resq_logo.dart';
import 'services/password_policy.dart';
import 'services/phone_policy.dart';
import 'shared/resq_toast.dart';
import 'shared/terms.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _isNetworkLoading = false; // Prevents double-tapping while sending data
  bool _googleBusy = false;
  DateTime? _birthdate;
  String? _barangay;
  final _terms = TermsConsentController();

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _terms.dispose();
    super.dispose();
  }

  Future<void> _processAccountRegistration() async {
    final String fullName = _nameController.text.trim();
    final String contactNo = PhonePolicy.normalize(_phoneController.text) ?? _phoneController.text.trim();
    final String email = _emailController.text.trim();
    final String password = _passwordController.text;
    final String confirmPassword = _confirmPasswordController.text;

    // 1. Validation Check: Ensure no empty fields are pushed to database columns
    if (fullName.isEmpty ||
        contactNo.isEmpty ||
        _birthdate == null ||
        _barangay == null ||
        email.isEmpty ||
        password.isEmpty) {
      _showFeedbackMessage('Please fill out all fields completely.');
      return;
    }

    // Responders call this number, so it must be a real mobile number
    final phoneError = PhonePolicy.check(contactNo);
    if (phoneError != null) {
      _showFeedbackMessage(phoneError);
      return;
    }

    // 2. Validation Check: Confirm verification matches perfectly
    if (password != confirmPassword) {
      _showFeedbackMessage('Passwords do not match. Please verify.');
      return;
    }

    // 3. Validation Check: Enforce the shared password policy
    final passwordError = PasswordPolicy.check(password);
    if (passwordError != null) {
      _showFeedbackMessage(passwordError);
      return;
    }

    // 4. Terms (a minor's parent may agree later; that never blocks signing up)
    final termsProblem = _terms.check();
    if (termsProblem != null) {
      _showFeedbackMessage(termsProblem);
      return;
    }

    setState(() => _isNetworkLoading = true);

    // 5. Fire network packet payload to your backend server architecture
    final result = await AuthService.registerCitizen(
      fullName: fullName,
      contactNo: contactNo,
      email: email,
      password: password,
      birthdate: BirthdatePicker.format(_birthdate!),
      barangay: _barangay!,
    );

    if (mounted) {
      setState(() => _isNetworkLoading = false);

      if (result.data != null) {
        try {
          await Terms.saveAcceptance(_terms); // still signed in until the email code
        } catch (_) {} // asked again at login if this didn't save
        if (!mounted) return;
        // Back to the login screen, which asks for the code just emailed
        Navigator.pop(context, result);
      } else {
        _showFeedbackMessage(result.error ?? 'Registration rejected. Email might be taken or backend is down.');
      }
    }
  }

  /// Same look as the text fields, for the birthdate and barangay pickers.
  InputDecoration _selectDecor(String hint, IconData icon, Color grey, Color border, Color brand) => InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(color: grey.withValues(alpha: 0.7)),
    prefixIcon: Icon(icon, color: grey, size: 20),
    filled: true,
    fillColor: ThemeService.instance.inputBackground,
    contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: brand),
    ),
  );

  void _showFeedbackMessage(String message) {
    ScaffoldMessenger.of(context).showResqSnackBar(SnackBar(content: Text(message)));
  }

  /// Google sign-up. The login screen finishes the sign-in (email code, home screen).
  Future<void> _handleGoogleSignUp() async {
    setState(() => _googleBusy = true);
    final result = await AuthService.loginWithGoogle();
    if (!mounted) return;
    setState(() => _googleBusy = false);
    // Both null: the user closed the Google window
    if (result.data == null && result.error == null) return;
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    const Color brandOrange = Color(0xFFFF6B00);
    final Color textDark = ts.isDark ? Colors.white : const Color(0xFF0F172A);
    const Color textGrey = Color(0xFF94A3B8);
    final Color borderGrey = ts.isDark ? const Color(0xFF374151) : const Color(0xFFE2E8F0);

    bool isDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;

    // Stays on top while the fields below scroll
    Widget header = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: borderGrey),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.arrow_back, size: 18, color: textDark),
              ),
            ),
            // Title sits between the back button and the logo
            Expanded(
              child: Column(
                children: [
                  Text(
                    'Create Account',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: textDark),
                  ),
                  const Text(
                    'Register as a ResQ citizen',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: textGrey),
                  ),
                ],
              ),
            ),
            const ResqLogo(size: 32, radius: 10),
          ],
        ),
      ],
    );

    Widget formContent = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildFieldLabel('Full Name', textDark),
        _buildTextField(
          _nameController,
          'Juan dela Cruz',
          Icons.person_outline,
          textGrey,
          borderGrey,
          brandOrange,
          textDark,
        ),
        const SizedBox(height: 10),
        _buildFieldLabel('Contact Number', textDark),
        _buildTextField(
          _phoneController,
          '09XX XXX XXXX',
          Icons.phone_android_outlined,
          textGrey,
          borderGrey,
          brandOrange,
          textDark,
          keyboardType: TextInputType.phone,
        ),
        const SizedBox(height: 10),
        _buildFieldLabel('Birthdate', textDark),
        BirthdatePicker(
          enabled: !_isNetworkLoading,
          onChanged: (d) {
            setState(() => _birthdate = d);
            _terms.setMinor(d != null && Terms.isMinor(d));
          },
          decoration: (hint) => _selectDecor(
            hint,
            Icons.cake_outlined,
            textGrey,
            borderGrey,
            brandOrange,
          ).copyWith(prefixIcon: null, contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12)),
          textStyle: TextStyle(fontSize: 14, color: ThemeService.instance.textPrimary),
          menuColor: ThemeService.instance.cardBackground,
        ),
        const SizedBox(height: 10),
        _buildFieldLabel('Barangay', textDark),
        ResqSelect<String>(
          value: _barangay,
          hint: 'Select your barangay',
          icon: Icons.home_outlined,
          height: 48,
          enabled: !_isNetworkLoading,
          options: [for (final b in IrigaAddress.barangays) ResqOption(b, b, icon: Icons.location_on_outlined)],
          onChanged: (v) => setState(() => _barangay = v),
        ),
        const SizedBox(height: 6),
        const Text(IrigaAddress.city, style: TextStyle(fontSize: 12, color: textGrey)),
        const SizedBox(height: 10),
        _buildFieldLabel('Email Address', textDark),
        _buildTextField(
          _emailController,
          'you@example.com',
          Icons.email_outlined,
          textGrey,
          borderGrey,
          brandOrange,
          textDark,
          keyboardType: TextInputType.emailAddress,
        ),
        const SizedBox(height: 10),
        _buildFieldLabel('Password', textDark),
        _buildPasswordField(
          _passwordController,
          '••••••••',
          _obscurePassword,
          textGrey,
          borderGrey,
          brandOrange,
          textDark,
          () => setState(() => _obscurePassword = !_obscurePassword),
        ),
        const SizedBox(height: 10),
        _buildFieldLabel('Confirm Password', textDark),
        _buildPasswordField(
          _confirmPasswordController,
          '••••••••',
          _obscureConfirmPassword,
          textGrey,
          borderGrey,
          brandOrange,
          textDark,
          () => setState(() => _obscureConfirmPassword = !_obscureConfirmPassword),
        ),
        const SizedBox(height: 14),
        TermsConsentSection(controller: _terms),
        const SizedBox(height: 14),
        ElevatedButton(
          onPressed: _isNetworkLoading ? null : _processAccountRegistration, // Disabled while transmitting
          style: ElevatedButton.styleFrom(
            backgroundColor: brandOrange,
            minimumSize: const Size.fromHeight(50),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child: _isNetworkLoading
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: ResqLoader(color: Colors.white),
                )
              : const Text(
                  'Create Account',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(child: Divider(color: borderGrey)),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text('or', style: TextStyle(color: textGrey, fontSize: 12)),
            ),
            Expanded(child: Divider(color: borderGrey)),
          ],
        ),
        const SizedBox(height: 18),
        OutlinedButton(
          onPressed: (_googleBusy || _isNetworkLoading) ? null : _handleGoogleSignUp,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(50),
            side: const BorderSide(color: brandOrange, width: 1.5),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child: _googleBusy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: ResqLoader(color: brandOrange),
                )
              : const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    GoogleLogo(size: 18),
                    SizedBox(width: 10),
                    Text(
                      'Sign up with Google',
                      style: TextStyle(color: brandOrange, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
        ),
      ],
    );

    final cardContainerBg = ts.isDark ? const Color(0xFF1F2937) : Colors.white;
    final pageBg = ts.isDark ? const Color(0xFF111827) : const Color(0xFFF9FAFB);

    return Scaffold(
      resizeToAvoidBottomInset: false, // keyboard covers the screen instead of pushing it up
      backgroundColor: isDesktop ? pageBg : cardContainerBg,
      // Header stays on top; a shadow appears only once content scrolls under it
      appBar: isDesktop
          ? null
          : AppBar(
              automaticallyImplyLeading: false,
              toolbarHeight: 72,
              titleSpacing: 28,
              backgroundColor: cardContainerBg,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 4,
              shadowColor: Colors.black26,
              title: header,
            ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 450),
          child: isDesktop
              ? Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: cardContainerBg,
                    borderRadius: BorderRadius.circular(32),
                    border: Border.all(color: ts.isDark ? const Color(0xFF374151) : const Color(0xFFE2E8F0)),
                    boxShadow: [
                      BoxShadow(
                        color: ts.isDark ? Colors.black.withValues(alpha: 0.3) : Colors.black.withValues(alpha: 0.05),
                        blurRadius: 20,
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      header,
                      const SizedBox(height: 16),
                      Flexible(child: SingleChildScrollView(child: formContent)),
                    ],
                  ),
                )
              : SafeArea(
                  top: false,
                  child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(28, 16, 28, 28), child: formContent),
                ),
        ),
      ),
    );
  }

  Widget _buildFieldLabel(String text, Color color) => Padding(
    padding: const EdgeInsets.only(bottom: 6.0),
    child: Text(
      text,
      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color),
    ),
  );

  Widget _buildTextField(
    TextEditingController ctrl,
    String hint,
    IconData icon,
    Color grey,
    Color border,
    Color brand,
    Color dark, {
    TextInputType keyboardType = TextInputType.text,
  }) {
    return TextField(
      controller: ctrl,
      keyboardType: keyboardType,
      style: TextStyle(color: dark, fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: grey.withValues(alpha: 0.7)),
        prefixIcon: Icon(icon, color: grey, size: 20),
        filled: true,
        fillColor: ThemeService.instance.inputBackground,
        contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: brand),
        ),
      ),
    );
  }

  Widget _buildPasswordField(
    TextEditingController ctrl,
    String hint,
    bool obscure,
    Color grey,
    Color border,
    Color brand,
    Color dark,
    VoidCallback onToggle,
  ) {
    return TextField(
      controller: ctrl,
      obscureText: obscure,
      style: TextStyle(color: dark, fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: grey.withValues(alpha: 0.7)),
        prefixIcon: Icon(Icons.lock_outline, color: grey, size: 20),
        suffixIcon: IconButton(
          icon: Icon(obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined, color: grey, size: 18),
          onPressed: onToggle,
        ),
        filled: true,
        fillColor: ThemeService.instance.inputBackground,
        contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: brand),
        ),
      ),
    );
  }
}
