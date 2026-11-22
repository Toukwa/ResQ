import 'shared/resq_loader.dart';
import 'services/friendly_error.dart';
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
import 'shared/profile_details_dialog.dart';
import 'shared/resq_logo.dart';
import 'shared/call_agencies_sheet.dart';
import 'shared/role_home.dart';
import 'shared/resq_toast.dart';
import 'shared/terms.dart';
import 'shared/google_logo.dart';
import 'services/firebase_rest.dart';
import 'shared/resq_text.dart';
import 'shared/splash_siren.dart' show resqLogoHeroTag, resqNameHeroTag;

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, this.trustedChecked = false, this.trustedUser});

  /// The startup screen already checked for a remembered device, so the form
  /// shows on the first frame (needed for the logo to glide into place).
  final bool trustedChecked;

  /// The remembered user found during startup, logged in straight away.
  final Map<String, dynamic>? trustedUser;

  static Future<Map<String, dynamic>?> findTrustedUser() => _LoginScreenState.findTrustedUser();

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _obscurePassword = true;
  late bool _checkingTrustedDevice = !widget.trustedChecked;
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final user = widget.trustedUser;
    if (user != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _navigateToRoleScreen(user);
      });
    } else if (!widget.trustedChecked) {
      _checkRememberedDevice();
    }
  }

  /// Startup's version of [_checkRememberedDevice]: the remembered user, or null.
  static Future<Map<String, dynamic>?> findTrustedUser() async {
    try {
      final userId = await SessionService.getTrustedUserId();
      if (userId == null) return null;
      final token = await SessionService.getOrCreateDeviceToken(userId);
      return await FirebaseService.checkTrustedDevice(userId: userId, deviceToken: token);
    } catch (_) {
      return null;
    }
  }

  /// On cold start, try to log in automatically if this device is remembered.
  Future<void> _checkRememberedDevice() async {
    try {
      final userId = await SessionService.getTrustedUserId();
      if (userId != null) {
        final token = await SessionService.getOrCreateDeviceToken(userId);
        final user = await FirebaseService.checkTrustedDevice(userId: userId, deviceToken: token);
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

  bool _loggingIn = false;
  bool _googleBusy = false;

  /// Returning Google users log in here (before, only the sign-up screen had Google).
  Future<void> _handleGoogleLogin() async {
    setState(() => _googleBusy = true);
    final result = await AuthService.loginWithGoogle();
    if (!mounted) return;
    setState(() => _googleBusy = false);
    // Both null: the user closed the Google window
    if (result.data == null && result.error == null) return;
    _handleLoginResult(result);
  }

  Future<void> _handleLogin() async {
    if (_loggingIn) return;
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showResqSnackBar(const SnackBar(content: Text('Please fill out all fields.')));
      return;
    }

    setState(() => _loggingIn = true);
    final result = await AuthService.loginCitizen(email: email, password: password);
    if (mounted) setState(() => _loggingIn = false);
    _handleLoginResult(result);
  }

  /// Report Now: straight to the report screen, no sign-up.
  Future<void> _openReportNow() async {
    // This phone already has a guest account: go straight back into it (no new account,
    // so its one-open-report limit still applies)
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: ResqLoader(color: AppColors.danger)),
    );
    final existing = await AuthService.resumeGuest();
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    if (existing != null) {
      await _openGuestHome(existing);
      return;
    }

    // No form here: the guest is named Guest#### and gives their name and phone when sending the report
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: ResqLoader(color: AppColors.danger)),
    );
    final result = await AuthService.quickReport();
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    if (result.data == null) {
      ScaffoldMessenger.of(context).showResqSnackBar(
        SnackBar(content: Text(result.error?.replaceFirst('Exception: ', '') ?? 'Something went wrong.')),
      );
      return;
    }
    await _openGuestHome(result.data!);
  }

  /// Saves the guest's session (so reopening the app keeps them in) and opens the report screen.
  Future<void> _openGuestHome(Map<String, dynamic> user) async {
    final userId = int.tryParse('${user['id']}') ?? 0;
    final name = '${user['fullName'] ?? 'Guest'}';
    await SessionService.saveSession(userId: userId, fullName: name, email: '', role: 'Citizen');
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => HomeScreen(citizenId: '$userId', userName: name),
      ),
    );
  }

  void _handleLoginResult(({Map<String, dynamic>? data, String? error}) result) {
    if (!mounted) return;

    if (result.data != null) {
      final userData = result.data!;
      if (userData['mfaRequired'] == true) {
        // MFA is enabled by SuperAdmin/User setting -> prompt 6-digit Email OTP code dialog
        _showMfaVerificationDialog(
          userId: userData['userId'],
          targetEmail: userData['targetEmail'] ?? '',
          maskedEmail: userData['maskedEmail'],
        );
      } else {
        // MFA disabled -> proceed directly
        final user = Map<String, dynamic>.from(userData['user'] as Map);
        _navigateToRoleScreen(user);
      }
    } else {
      final rawError = result.error ?? 'Invalid credentials or server connection failed.';
      final cleanError = rawError.replaceFirst('HttpException: ', '').replaceFirst('Exception: ', '');
      ScaffoldMessenger.of(
        context,
      ).showResqSnackBar(SnackBar(content: Text(cleanError), backgroundColor: AppColors.danger));
    }
  }

  Future<void> _showMfaVerificationDialog({
    required int userId,
    required String targetEmail,
    String? maskedEmail,
  }) async {
    final otpController = TextEditingController();
    bool isVerifying = false;
    var verified = false;
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
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.brand.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.mark_email_read_outlined, color: AppColors.brand, size: 24),
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
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: ts.isDark ? const Color(0xFF1E3A8A) : const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: ts.isDark ? const Color(0xFF1D4ED8) : const Color(0xFFBFDBFE)),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.email_outlined,
                        size: 16,
                        color: ts.isDark ? const Color(0xFF93C5FD) : const Color(0xFF2563EB),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Enter the code sent to your email (valid for 5 mins).',
                          style: TextStyle(
                            fontSize: 12,
                            color: ts.isDark ? const Color(0xFF93C5FD) : const Color(0xFF1D4ED8),
                          ),
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
                      borderSide: const BorderSide(color: AppColors.brand),
                    ),
                  ),
                ),
                if (errorMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(errorMessage!, style: const TextStyle(color: AppColors.danger, fontSize: 12)),
                ],
                const SizedBox(height: 4),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogCtx).pop(),
                child: Text(
                  'Cancel',
                  style: TextStyle(color: ts.isDark ? Colors.grey.shade400 : const Color(0xFF64748B)),
                ),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.brand,
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
                          final result = await FirebaseService.verifyMfa(userId: userId, otpCode: code);

                          if (result != null && result['success'] == true) {
                            verified = true;
                            // Trust this device so the OTP isn't asked again here for 7 days
                            final token = await SessionService.getOrCreateDeviceToken(userId);
                            await FirebaseService.trustDevice(userId: userId, deviceToken: token);
                            await SessionService.saveTrustedUserId(userId);
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
                            errorMessage = friendlyError(e);
                          });
                        }
                      },
                child: isVerifying
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: ResqLoader(color: Colors.white),
                      )
                    : const Text('Verify & Login'),
              ),
            ],
          );
        },
      ),
    );
    // Closed without the code: don't leave the password sign-in active in the background
    if (!verified) await FirebaseService.signOut();
  }

  Future<void> _navigateToRoleScreen(Map<String, dynamic> userData) async {
    // Citizens from Google sign-in (or older accounts) still need a birthdate and address
    final missingDetails =
        (userData['birthdate'] ?? '').toString().isEmpty || (userData['barangay'] ?? '').toString().isEmpty;
    final isCitizen = (userData['role'] ?? 'Citizen') == 'Citizen' && userData['guest'] != true;
    final needsPassword = isCitizen && await FirebaseService.needsPassword();
    if (!mounted) return;
    if (isCitizen && (missingDetails || needsPassword)) {
      final saved = await showProfileDetailsDialog(
        context,
        askDetails: missingDetails,
        askPassword: needsPassword,
        email: (userData['email'] ?? '').toString(),
      );
      if (!saved) {
        await FirebaseService.signOut();
        return;
      }
      if (!mounted) return;
    }
    // Accounts that never saw the sign-up checkbox (Google, older ones) or a newer Terms version
    if (isCitizen && !await Terms.accepted()) {
      final birth = DateTime.tryParse('${await Rtdb.get('users/${FirebaseAuthRest.uid}/birthdate') ?? ''}');
      if (!mounted) return;
      if (!await showTermsAcceptanceDialog(context, birthdate: birth)) {
        await FirebaseService.signOut();
        return;
      }
      if (!mounted) return;
    }
    final userId = int.tryParse(userData['id']?.toString() ?? '0') ?? 0;
    final fullName = userData['fullName']?.toString() ?? 'User';
    final email = userData['email']?.toString() ?? '';
    final userRole = userData['role']?.toString() ?? 'Citizen';
    final deptIdRaw = userData['deptID'] ?? userData['dept_ID'];
    String department = (userData['department'] ?? userData['Department_Name'] ?? userData['dept'] ?? '')
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
    // An agency admin needs an agency; without one they would see every agency's reports
    if (homeForRole(userRole) == RoleHome.admin && department == 'ALL') {
      await FirebaseService.signOut();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showResqSnackBar(const SnackBar(
        content: Text('This admin account has no agency yet. Ask the EOC to set one.'),
        backgroundColor: AppColors.danger,
      ));
      return;
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

    final home = homeForRole(userRole);
    if (home == RoleHome.superAdmin) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => SuperAdminShell(isSuperAdmin: true, userId: userId)),
      );
    } else if (home == RoleHome.admin) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => AdminShell(userId: userId, department: department),
        ),
      );
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => HomeScreen(citizenId: userId.toString(), userName: fullName),
        ),
      );
    }
  }

  Future<void> _handleForgotPassword() async {
    final email = _emailController.text.trim();

    if (email.isEmpty) {
      ScaffoldMessenger.of(context).showResqSnackBar(const SnackBar(content: Text('Enter your email address first.')));
      return;
    }

    try {
      await FirebaseService.sendPasswordReset(email);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showResqSnackBar(SnackBar(content: Text('Password reset link sent to $email.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showResqSnackBar(
        SnackBar(content: Text(friendlyError(e)), backgroundColor: AppColors.danger),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    const Color brandOrange = AppColors.brand;
    final Color textDark = ts.isDark ? Colors.white : const Color(0xFF0F172A);
    const Color textGrey = Color(0xFF94A3B8);
    final Color borderGrey = ts.isDark ? const Color(0xFF374151) : const Color(0xFFE2E8F0);
    final Color cardContainerBg = ts.isDark ? const Color(0xFF1F2937) : Colors.white;
    final Color pageBg = ts.isDark ? const Color(0xFF111827) : const Color(0xFFF3F4F6);

    bool isDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;

    Widget loginForm = SingleChildScrollView(
      padding: EdgeInsets.symmetric(horizontal: isDesktop ? 40 : 28, vertical: isDesktop ? 30 : 50),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Column(
              children: [
                const Hero(tag: resqLogoHeroTag, child: ResqLogo(size: 76, radius: 0)),
                const SizedBox(height: 4),
                Hero(
                  tag: resqNameHeroTag,
                  // Scale the text with the flight so 56pt shrinks smoothly to 36pt
                  flightShuttleBuilder: (_, _, _, _, to) => FittedBox(child: to.widget),
                  child: const Material(
                    type: MaterialType.transparency,
                    child: Text(
                      "ResQ",
                      style: TextStyle(fontFamily: 'Bangers', fontSize: 36, height: 1.0, letterSpacing: 1.5, color: resqOrange),
                    ),
                  ),
                ),
                const Text('Emergency Response Portal', style: TextStyle(fontSize: 12, color: textGrey)),
              ],
            ),
          ),
          const SizedBox(height: 40),
          Text(
            'Email',
            style: TextStyle(fontWeight: FontWeight.w600, color: textDark),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            style: TextStyle(color: textDark),
            decoration: _inputDecor('Enter Email', Icons.email_outlined, borderGrey, brandOrange),
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
              onToggle: () => setState(() => _obscurePassword = !_obscurePassword),
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              onTap: _handleForgotPassword,
              child: const Text(
                'Forgot password?',
                style: TextStyle(color: brandOrange, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(height: 30),
          ElevatedButton(
            onPressed: _loggingIn ? null : _handleLogin,
            style: ElevatedButton.styleFrom(
              backgroundColor: brandOrange,
              disabledBackgroundColor: brandOrange.withValues(alpha: 0.6),
              minimumSize: const Size.fromHeight(50),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: _loggingIn
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: ResqLoader(color: Colors.white),
                  )
                : const Text(
                    'Log In',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
          ),
          // Phones only: sign-up is for citizens; the desktop app is for staff
          if (!isDesktop) ...[
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _googleBusy || _loggingIn ? null : _handleGoogleLogin,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                side: const BorderSide(color: brandOrange, width: 1.5),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: _googleBusy
                  ? const SizedBox(width: 20, height: 20, child: ResqLoader(color: brandOrange))
                  : const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        GoogleLogo(size: 18),
                        SizedBox(width: 10),
                        Text('Continue with Google', style: TextStyle(color: brandOrange, fontWeight: FontWeight.bold)),
                      ],
                    ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text("Don't have an account? ", style: TextStyle(color: textGrey)),
                GestureDetector(
                  onTap: () async {
                    // Register returns a result when the user picked Google there
                    final googleResult = await Navigator.push<({Map<String, dynamic>? data, String? error})>(
                      context,
                      MaterialPageRoute(builder: (context) => const RegisterScreen()),
                    );
                    if (googleResult != null) _handleLoginResult(googleResult);
                  },
                  child: const Text(
                    'Create one',
                    style: TextStyle(color: brandOrange, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );

    if (_checkingTrustedDevice) {
      return Scaffold(
        resizeToAvoidBottomInset: false, // keyboard covers the screen instead of pushing it up
        backgroundColor: pageBg,
        body: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ResqLoader(color: AppColors.brand),
              SizedBox(height: 16),
              Text('Checking saved session…', style: TextStyle(color: Color(0xFF94A3B8))),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      resizeToAvoidBottomInset: false, // keyboard covers the screen instead of pushing it up
      backgroundColor: isDesktop ? pageBg : cardContainerBg,
      // Phones only: emergency hotlines pinned to the bottom, apart from the login form
      bottomNavigationBar: isDesktop
          ? null
          : SafeArea(
              child: Container(
                padding: const EdgeInsets.fromLTRB(28, 12, 28, 12),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: borderGrey)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _openReportNow,
                        icon: const Icon(Icons.campaign_rounded, color: Colors.white),
                        label: const Text(
                          'Report Now',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.danger,
                          minimumSize: const Size.fromHeight(48),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => showCallAgenciesSheet(context),
                        icon: const Icon(Icons.phone_in_talk_rounded, color: AppColors.danger),
                        label: const Text(
                          'Call Agencies',
                          style: TextStyle(color: AppColors.danger, fontWeight: FontWeight.bold),
                        ),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                          side: const BorderSide(color: AppColors.danger),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 450),
          child: isDesktop
              ? Card(
                  elevation: 8,
                  color: cardContainerBg,
                  surfaceTintColor: Colors.transparent,
                  shadowColor: ts.isDark ? Colors.black.withValues(alpha: 0.5) : Colors.black.withValues(alpha: 0.1),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
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
            tooltip: 'Show or hide password',
              icon: Icon(
                _obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
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
