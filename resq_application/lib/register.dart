import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'auth_service.dart';
import 'services/theme_service.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _isNetworkLoading = false; // Prevents double-tapping while sending data

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  // Master execution logic handler to write data into XAMPP via Node.js
  Future<void> _processAccountRegistration() async {
    final String fullName = _nameController.text.trim();
    final String contactNo = _phoneController.text.trim();
    final String email = _emailController.text.trim();
    final String password = _passwordController.text;
    final String confirmPassword = _confirmPasswordController.text;

    // 1. Validation Check: Ensure no empty fields are pushed to database columns
    if (fullName.isEmpty ||
        contactNo.isEmpty ||
        email.isEmpty ||
        password.isEmpty) {
      _showFeedbackMessage('Please fill out all fields completely.');
      return;
    }

    // 2. Validation Check: Confirm verification matches perfectly
    if (password != confirmPassword) {
      _showFeedbackMessage('Passwords do not match. Please verify.');
      return;
    }

    // 3. Validation Check: Ensure reasonable baseline criteria length
    if (password.length < 6) {
      _showFeedbackMessage('Password must be at least 6 characters long.');
      return;
    }

    setState(() => _isNetworkLoading = true);

    // 4. Fire network packet payload to your backend server architecture
    final result = await AuthService.registerCitizen(
      fullName: fullName,
      contactNo: contactNo,
      email: email,
      password: password,
    );

    if (mounted) {
      setState(() => _isNetworkLoading = false);

      if (result.success) {
        // Pop up contextual notification success dialog box
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Account successfully created! You can now log in.'),
            backgroundColor: Colors.green,
          ),
        );
        // Take them backward down the application tree layout stack straight to the login UI
        Navigator.pop(context);
      } else {
        _showFeedbackMessage(
          result.error ?? 'Registration rejected. Email might be taken or backend is down.',
        );
      }
    }
  }

  void _showFeedbackMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    const Color brandOrange = Color(0xFFFF6B00);
    final Color textDark = ts.isDark ? Colors.white : const Color(0xFF0F172A);
    const Color textGrey = Color(0xFF94A3B8);
    final Color borderGrey = ts.isDark ? const Color(0xFF374151) : const Color(0xFFE2E8F0);

    bool isDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;

    Widget formContent = Column(
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
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: brandOrange,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.shield_outlined,
                color: Colors.white,
                size: 18,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          'Create Account',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: textDark,
          ),
        ),
        const Text(
          'Register as a ResQ citizen',
          style: TextStyle(fontSize: 12, color: textGrey),
        ),
        const SizedBox(height: 16),
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
          () => setState(
            () => _obscureConfirmPassword = !_obscureConfirmPassword,
          ),
        ),
        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: _isNetworkLoading
              ? null
              : _processAccountRegistration, // Disabled while transmitting
          style: ElevatedButton.styleFrom(
            backgroundColor: brandOrange,
            minimumSize: const Size.fromHeight(50),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          child: _isNetworkLoading
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2,
                  ),
                )
              : const Text(
                  'Create Account',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
        ),
      ],
    );

    final cardContainerBg = ts.isDark ? const Color(0xFF1F2937) : Colors.white;
    final pageBg = ts.isDark ? const Color(0xFF111827) : const Color(0xFFF9FAFB);

    return Scaffold(
      backgroundColor: isDesktop ? pageBg : cardContainerBg,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 450),
          child: isDesktop
              ? Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: cardContainerBg,
                    borderRadius: BorderRadius.circular(32),
                    border: Border.all(
                      color: ts.isDark ? const Color(0xFF374151) : const Color(0xFFE2E8F0),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: ts.isDark ? Colors.black.withValues(alpha: 0.3) : Colors.black.withValues(alpha: 0.05),
                        blurRadius: 20,
                      ),
                    ],
                  ),
                  child: formContent,
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(28),
                  child: formContent,
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
        fillColor: const Color(0xFFF8FAFC),
        contentPadding: const EdgeInsets.symmetric(
          vertical: 12,
          horizontal: 16,
        ),
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
          icon: Icon(
            obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
            color: grey,
            size: 18,
          ),
          onPressed: onToggle,
        ),
        filled: true,
        fillColor: const Color(0xFFF8FAFC),
        contentPadding: const EdgeInsets.symmetric(
          vertical: 12,
          horizontal: 16,
        ),
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
