import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'register.dart';
import 'auth_service.dart';
import 'citizen/home_screen.dart';
import 'superadmin/super_admin_shell.dart';
import 'admin/admin_shell.dart';
import 'services/firebase_services.dart';
import 'services/session_service.dart';
import 'services/theme_service.dart';


class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _obscurePassword = true;
  bool _checkingTrustedDevice = true;
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _checkRememberedDevice();
  }

  /// On cold start, try to log in automatically if this device is remembered.
  Future<void> _checkRememberedDevice() async {
    try {
      final userId = await SessionService.getTrustedUserId();
      if (userId != null) {
        final token = await SessionService.getOrCreateDeviceToken(userId);
        final user = await FirebaseService.checkTrustedDevice(
          userId: userId,
          deviceToken: token,
        );
        if (user != null && mounted) {
          _navigateToRoleScreen(user);
          return;
        }
      }
    } catch (_) {
      // Silent – fall through to normal login screen
    } finally {
      if (mounted) setState(() => _checkingTrustedDevice = false);
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill out all fields.')),
      );
      return;
    }

    final result = await AuthService.loginCitizen(
      email: email,
      password: password,
    );

    if (!mounted) return;

    if (result.data != null) {
      final userData = result.data!;
      if (userData['mfaRequired'] == true) {
        // MFA is enabled by SuperAdmin/User setting -> prompt 6-digit Email OTP code dialog
        _showMfaVerificationDialog(
          userId: userData['userId'],
          targetEmail: userData['targetEmail'] ?? '',
          maskedEmail: userData['maskedEmail'],
          testOtpCode: userData['otpCode'] as String?,
        );
      } else {
        // MFA disabled -> proceed directly
        final user = Map<String, dynamic>.from(userData['user'] as Map);
        _navigateToRoleScreen(user);
      }
    } else {
      final rawError = result.error ?? 'Invalid credentials or server connection failed.';
      final cleanError = rawError
          .replaceFirst('HttpException: ', '')
          .replaceFirst('Exception: ', '');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(cleanError),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  Future<void> _showMfaVerificationDialog({
    required int userId,
    required String targetEmail,
    String? maskedEmail,
    String? testOtpCode,
  }) async {
    final otpController = TextEditingController();
    bool isVerifying = false;
    bool rememberDevice = false;
    String? errorMessage;

    final displayEmail = maskedEmail ?? targetEmail;

    final ts = ThemeService.instance;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: ts.isDark ? const Color(0xFF1F2937) : Colors.white,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF6B00).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.mark_email_read_outlined,
                    color: Color(0xFFFF6B00),
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  'Email MFA Verification',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                    color: ts.isDark ? Colors.white : const Color(0xFF0F172A),
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'A 6-digit security verification code has been sent to your email address:\n$displayEmail',
                  style: TextStyle(
                    fontSize: 13,
                    color: ts.isDark ? Colors.grey.shade300 : const Color(0xFF475569),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),
                if (testOtpCode != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: ts.isDark ? const Color(0xFF78350F) : const Color(0xFFFEF3C7),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: ts.isDark ? const Color(0xFF92400E) : const Color(0xFFFCD34D)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.info_outline, size: 14, color: ts.isDark ? const Color(0xFFFDE68A) : const Color(0xFFD97706)),
                        const SizedBox(width: 6),
                        Text(
                          'Test OTP Code: $testOtpCode',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: ts.isDark ? const Color(0xFFFDE68A) : const Color(0xFFB45309),
                          ),
                        ),
                      ],
                    ),
                  ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: ts.isDark ? const Color(0xFF1E3A8A) : const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: ts.isDark ? const Color(0xFF1D4ED8) : const Color(0xFFBFDBFE)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.email_outlined, size: 16, color: ts.isDark ? const Color(0xFF93C5FD) : const Color(0xFF2563EB)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Check your terminal log or enter code above (valid for 5 mins).',
                          style: TextStyle(fontSize: 12, color: ts.isDark ? const Color(0xFF93C5FD) : const Color(0xFF1D4ED8)),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: otpController,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  autofocus: true,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 8,
                    color: ts.isDark ? Colors.white : const Color(0xFF0F172A),
                  ),
                  decoration: InputDecoration(
                    hintText: '000000',
                    hintStyle: TextStyle(color: ts.isDark ? Colors.grey.shade500 : const Color(0xFF94A3B8)),
                    counterText: '',
                    filled: true,
                    fillColor: ts.isDark ? const Color(0xFF374151) : const Color(0xFFF8FAFC),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: ts.isDark ? const Color(0xFF4B5563) : const Color(0xFFE2E8F0)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Color(0xFFFF6B00)),
                    ),
                  ),
                ),
                if (errorMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    errorMessage!,
                    style: const TextStyle(color: Color(0xFFEF4444), fontSize: 12),
                  ),
                ],
                const SizedBox(height: 4),
                // ── Remember this device checkbox ──────────────────
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => setDialogState(() => rememberDevice = !rememberDevice),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: Checkbox(
                            value: rememberDevice,
                            activeColor: const Color(0xFFFF6B00),
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            onChanged: (v) => setDialogState(() => rememberDevice = v ?? false),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Remember this device for 30 days',
                            style: TextStyle(fontSize: 13, color: ts.isDark ? Colors.grey.shade300 : const Color(0xFF475569)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogCtx).pop(),
                child: Text('Cancel', style: TextStyle(color: ts.isDark ? Colors.grey.shade400 : const Color(0xFF64748B))),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF6B00),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: isVerifying
                    ? null
                    : () async {
                        final code = otpController.text.trim();
                        if (code.length != 6) {
                          setDialogState(() => errorMessage = 'Please enter a 6-digit code');
                          return;
                        }

                        setDialogState(() {
                          isVerifying = true;
                          errorMessage = null;
                        });

                        try {
                          final result = await FirebaseService.verifyMfa(
                            userId: userId,
                            otpCode: code,
                          );

                          if (result != null && result['success'] == true) {
                            // Register device if user chose to be remembered
                            if (rememberDevice) {
                              final token = await SessionService.getOrCreateDeviceToken(userId);
                              await FirebaseService.trustDevice(
                                userId: userId,
                                deviceToken: token,
                              );
                              await SessionService.saveTrustedUserId(userId);
                            }
                            if (dialogCtx.mounted) Navigator.of(dialogCtx).pop();
                            if (!mounted) return;
                            final verifiedUser = Map<String, dynamic>.from(result['user'] as Map);
                            _navigateToRoleScreen(verifiedUser);
                          } else {
                            setDialogState(() {
                              isVerifying = false;
                              errorMessage = result?['error'] ?? 'Invalid code';
                            });
                          }
                        } catch (e) {
                          setDialogState(() {
                            isVerifying = false;
                            errorMessage = e.toString();
                          });
                        }
                      },
                child: isVerifying
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Verify & Login'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _navigateToRoleScreen(Map<String, dynamic> userData) async {
    final userId = int.tryParse(userData['id']?.toString() ?? '0') ?? 0;
    final fullName = userData['fullName']?.toString() ?? 'User';
    final email = userData['email']?.toString() ?? '';
    final userRole = userData['role']?.toString() ?? 'Citizen';
    final deptIdRaw = userData['deptID'] ?? userData['dept_ID'];
    String department = (userData['department'] ??
            userData['Department_Name'] ??
            userData['dept'] ??
            '')
        .toString()
        .trim()
        .toUpperCase();

    if (department.isEmpty || department == 'NULL') {
      final idNum = int.tryParse(deptIdRaw?.toString() ?? '0') ?? 0;
      if (idNum == 1) {
        department = 'PNP';
      } else if (idNum == 2) {
        department = 'BFP';
      } else if (idNum == 3) {
        department = 'CDRRMO';
      } else {
        department = 'ALL';
      }
    }

    // Persist session to local storage for seamless continuous session
    await SessionService.saveSession(
      userId: userId,
      fullName: fullName,
      email: email,
      role: userRole,
      department: department,
    );

    if (!mounted) return;

    if (userRole == 'Superadmin') {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => SuperAdminShell(
            isSuperAdmin: true,
            userId: userId,
          ),
        ),
      );
    } else if (userRole == 'Admin') {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => AdminShell(
            userId: userId,
            department: department,
          ),
        ),
      );
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => HomeScreen(
            citizenId: userId.toString(),
            userName: fullName,
          ),
        ),
      );
    }
  }

  Future<void> _handleForgotPassword() async {
    final email = _emailController.text.trim();

    if (email.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter your email address first.')),
      );
      return;
    }

    try {
      await FirebaseService.sendPasswordReset(email);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Password reset link sent to $email.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('HttpException: ', '')),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    const Color brandOrange = Color(0xFFFF6B00);
    final Color textDark = ts.isDark ? Colors.white : const Color(0xFF0F172A);
    const Color textGrey = Color(0xFF94A3B8);
    final Color borderGrey = ts.isDark ? const Color(0xFF374151) : const Color(0xFFE2E8F0);
    final Color cardContainerBg = ts.isDark ? const Color(0xFF1F2937) : Colors.white;
    final Color pageBg = ts.isDark ? const Color(0xFF111827) : const Color(0xFFF3F4F6);

    bool isDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;

    Widget loginForm = SingleChildScrollView(
      padding: EdgeInsets.symmetric(
        horizontal: isDesktop ? 40 : 28,
        vertical: isDesktop ? 30 : 50,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Column(
              children: [
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: brandOrange,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(
                    Icons.shield_outlined,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  "ResQ",
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    color: textDark,
                  ),
                ),
                const Text(
                  'Emergency Response Portal',
                  style: TextStyle(fontSize: 12, color: textGrey),
                ),
              ],
            ),
          ),
          const SizedBox(height: 40),
          Text(
            'Email / Username',
            style: TextStyle(fontWeight: FontWeight.w600, color: textDark),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _emailController,
            style: TextStyle(color: textDark),
            decoration: _inputDecor(
              'you@example.com',
              Icons.person_outline,
              borderGrey,
              brandOrange,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Password',
            style: TextStyle(fontWeight: FontWeight.w600, color: textDark),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _passwordController,
            obscureText: _obscurePassword,
            style: TextStyle(color: textDark),
            decoration: _inputDecor(
              'Enter your password',
              Icons.lock_outline,
              borderGrey,
              brandOrange,
              isPassword: true,
              onToggle: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              onTap: _handleForgotPassword,
              child: const Text(
                'Forgot password?',
                style: TextStyle(
                  color: brandOrange,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(height: 30),
          ElevatedButton(
            onPressed: _handleLogin,
            style: ElevatedButton.styleFrom(
              backgroundColor: brandOrange,
              minimumSize: const Size.fromHeight(50),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: const Text(
              'Log In',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                "Don't have an account? ",
                style: TextStyle(color: textGrey),
              ),
              GestureDetector(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const RegisterScreen(),
                  ),
                ),
                child: const Text(
                  'Create one',
                  style: TextStyle(
                    color: brandOrange,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );

    if (_checkingTrustedDevice) {
      return Scaffold(
        backgroundColor: pageBg,
        body: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Color(0xFFFF6B00)),
              SizedBox(height: 16),
              Text('Checking saved session…',
                  style: TextStyle(color: Color(0xFF94A3B8))),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: isDesktop ? pageBg : cardContainerBg,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 450),
          child: isDesktop
              ? Card(
                  elevation: 8,
                  color: cardContainerBg,
                  surfaceTintColor: Colors.transparent,
                  shadowColor: ts.isDark ? Colors.black.withValues(alpha: 0.5) : Colors.black.withValues(alpha: 0.1),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: loginForm,
                )
              : loginForm,
        ),
      ),
    );
  }

  InputDecoration _inputDecor(
    String hint,
    IconData icon,
    Color border,
    Color brand, {
    bool isPassword = false,
    VoidCallback? onToggle,
  }) {
    final ts = ThemeService.instance;
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: ts.isDark ? Colors.grey.shade400 : const Color(0xFF94A3B8)),
      prefixIcon: Icon(icon, color: ts.isDark ? Colors.grey.shade400 : const Color(0xFF94A3B8), size: 20),
      suffixIcon: isPassword
          ? IconButton(
              icon: Icon(
                _obscurePassword
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                size: 18,
                color: ts.isDark ? Colors.grey.shade400 : const Color(0xFF94A3B8),
              ),
              onPressed: onToggle,
            )
          : null,
      filled: true,
      fillColor: ts.isDark ? const Color(0xFF374151) : const Color(0xFFF8FAFC),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: ts.isDark ? const Color(0xFF4B5563) : border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: brand),
      ),
    );
  }
}
