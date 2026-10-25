import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/admin_data.dart';
import '../services/firebase_rest.dart';
import '../services/firebase_services.dart';
import '../services/media_upload.dart';
import '../services/session_service.dart';
import '../services/sound_service.dart';
import '../services/theme_service.dart';
import '../shared/display_settings.dart';
import '../shared/resq_toast.dart';
import '../shared/terms.dart';
import 'guest_registration_screen.dart';
import '../shared/resq_text.dart';

/// Citizen account & app settings: profile summary, edit profile, dark mode,
/// sound, password and log out. Guests only see a prompt to register.
/// Pop-ups use the same bottom sheets and dialogs as the home screen.
class CitizenSettingsScreen extends StatefulWidget {
  const CitizenSettingsScreen({super.key});

  @override
  State<CitizenSettingsScreen> createState() => _CitizenSettingsScreenState();
}

class _CitizenSettingsScreenState extends State<CitizenSettingsScreen> {
  static const _orange = Color(0xFFFF6B00);
  static const _red = Color(0xFFEF4444);
  static const _green = Color(0xFF16A34A);
  static const _blue = Color(0xFF2563EB);
  static const _purple = Color(0xFF7C3AED);

  Map<String, dynamic>? _profile;
  bool _loading = true;
  bool _uploadingPhoto = false;
  bool _sound = SoundService.enabled;
  bool _guardianPending = false;

  bool get _isGuest => _profile?['guest'] == true;
  int get _userId => int.tryParse('${_profile?['id']}') ?? 0;
  ThemeService get ts => ThemeService.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await Rtdb.get('users/${FirebaseAuthRest.uid}');
      if (p is Map) _profile = Map<String, dynamic>.from(p);
      if (_profile != null && !_isGuest) {
        final s = await AdminData.getSettings(_userId);
        _sound = '${s['sound_alerts']}' != '0';
        _guardianPending = _profile?['guardianPending'] == true;
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String msg, {bool error = false}) {
    ScaffoldMessenger.of(context).showResqSnackBar(
      SnackBar(content: Text(msg), backgroundColor: error ? Colors.redAccent : const Color(0xFF27AE60)),
    );
  }

  Future<void> _saveSetting(Map<String, dynamic> change) async {
    try {
      await AdminData.updateSettings(_userId, change);
    } catch (_) {
      _toast("Couldn't save that setting. Check your connection.", error: true);
    }
  }

  // ─── shared pop-up pieces (same look as the home screen) ─────────────────

  /// Bottom sheet with a grab handle and an icon + title header. Lifts above the keyboard.
  Future<T?> _sheet<T>({
    required IconData icon,
    required String title,
    String? subtitle,
    Color color = _orange,
    required Widget Function(BuildContext sheetContext, StateSetter setSheet) body,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      backgroundColor: ts.cardBackground,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheet) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheetContext).bottom),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(color: ts.borderColor, borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      _chip(icon, color, size: 22),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: ts.textPrimary),
                            ),
                            if (subtitle != null)
                              Text(subtitle, style: TextStyle(fontSize: 12, color: ts.textSecondary)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  body(sheetContext, setSheet),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Rounded square icon on a pale tint of [color].
  Widget _chip(IconData icon, Color color, {double size = 20}) => Container(
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: color.withValues(alpha: ts.isDark ? 0.2 : 0.1),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Icon(icon, color: color, size: size),
  );

  /// Big tappable card, like Take a Photo / Record a Video on the home screen.
  Widget _optionCard(IconData icon, String title, String subtitle, VoidCallback onTap) => Expanded(
    child: Material(
      color: ts.isDark ? const Color(0xFF111827) : const Color(0xFFFFF7ED),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _orange.withValues(alpha: 0.35), width: 1.5),
          ),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: const BoxDecoration(color: _orange, shape: BoxShape.circle),
                child: Icon(icon, color: Colors.white, size: 28),
              ),
              const SizedBox(height: 12),
              Text(
                title,
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: ts.textPrimary),
              ),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(fontSize: 12, color: ts.textSecondary)),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _field(
    TextEditingController c, {
    required String hint,
    required IconData icon,
    TextInputType? keyboard,
    bool obscure = false,
    String? error,
    bool autofocus = false,
  }) => TextField(
    controller: c,
    autofocus: autofocus,
    keyboardType: keyboard,
    obscureText: obscure,
    style: TextStyle(color: ts.textPrimary),
    decoration: InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: ts.textMuted),
      errorText: error,
      errorMaxLines: 3,
      prefixIcon: Icon(icon, color: ts.textMuted, size: 20),
      filled: true,
      fillColor: ts.inputBackground,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: ts.borderColor),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: _orange, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: _red),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: _red, width: 1.5),
      ),
    ),
  );

  Widget _primaryButton(String label, VoidCallback? onPressed, {Color color = _orange, bool busy = false}) => SizedBox(
    height: 50,
    child: ElevatedButton(
      onPressed: busy ? null : onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        disabledBackgroundColor: color.withValues(alpha: 0.5),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      child: busy
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
            )
          : Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
    ),
  );

  // ─── profile edits ────────────────────────────────────────────────────

  Future<void> _changePhoto() async {
    if (_guardianPending) {
      _toast('Ask a parent or guardian to agree to the Terms first (Settings > Parent or guardian).', error: true);
      return;
    }
    final source = await _sheet<ImageSource>(
      icon: Icons.account_circle_rounded,
      title: 'Profile Picture',
      subtitle: 'Shown on your account',
      body: (sheet, _) => Row(
        children: [
          _optionCard(
            Icons.photo_camera_rounded,
            'Take a Photo',
            'Use the camera',
            () => Navigator.pop(sheet, ImageSource.camera),
          ),
          const SizedBox(width: 12),
          _optionCard(
            Icons.photo_library_rounded,
            'From Gallery',
            'Pick a saved photo',
            () => Navigator.pop(sheet, ImageSource.gallery),
          ),
        ],
      ),
    );
    if (source == null) return;
    final picked = await ImagePicker().pickImage(source: source, maxWidth: 600, imageQuality: 80);
    if (picked == null) return;
    setState(() => _uploadingPhoto = true);
    try {
      final url = await MediaUpload.upload(File(picked.path));
      await FirebaseService.updateMyProfile(photoUrl: url);
      setState(() => _profile?['photoUrl'] = url);
      _toast('Profile picture updated');
    } catch (e) {
      _toast("Couldn't update your picture. $e", error: true);
    }
    if (mounted) setState(() => _uploadingPhoto = false);
  }

  /// One-field edit in a bottom sheet (name, phone number).
  Future<void> _editField({
    required IconData icon,
    required String title,
    required String subtitle,
    required String initial,
    required String hint,
    required TextInputType keyboard,
    required String? Function(String) validate,
    required Future<void> Function(String) save,
  }) async {
    final controller = TextEditingController(text: initial);
    String? error;
    bool busy = false;
    await _sheet<void>(
      icon: icon,
      title: title,
      subtitle: subtitle,
      body: (sheet, setSheet) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _field(controller, hint: hint, icon: icon, keyboard: keyboard, error: error, autofocus: true),
          const SizedBox(height: 16),
          _primaryButton('Save', () async {
            final v = controller.text.trim();
            final e = validate(v);
            if (e != null) return setSheet(() => error = e);
            if (v == initial) return Navigator.pop(sheet);
            setSheet(() => busy = true);
            try {
              await save(v);
              if (sheet.mounted) Navigator.pop(sheet);
              _toast('$title saved');
            } catch (e) {
              setSheet(() {
                busy = false;
                error = cleanErrorText("Couldn't save. $e");
              });
            }
          }, busy: busy),
        ],
      ),
    );
  }

  void _editName() => _editField(
    icon: Icons.badge_rounded,
    title: 'Name',
    subtitle: 'How responders will address you',
    initial: '${_profile?['fullName'] ?? ''}',
    hint: 'Your full name',
    keyboard: TextInputType.name,
    validate: (v) => v.length < 2 ? 'Please enter your name' : (v.length > 60 ? 'Name is too long' : null),
    save: (v) async {
      await FirebaseService.updateMyProfile(fullName: v);
      await SessionService.updateFullName(v);
      setState(() => _profile?['fullName'] = v);
    },
  );

  void _editPhone() => _editField(
    icon: Icons.phone_rounded,
    title: 'Phone Number',
    subtitle: 'Responders may call this number',
    initial: '${_profile?['contactNo'] ?? ''}',
    hint: '09XXXXXXXXX',
    keyboard: TextInputType.phone,
    validate: (v) => RegExp(r'^(09|\+639)\d{9}$').hasMatch(v) ? null : 'Use 09XXXXXXXXX format',
    save: (v) async {
      await FirebaseService.updateMyProfile(contactNo: v);
      setState(() => _profile?['contactNo'] = v);
    },
  );

  Future<void> _changePassword() async {
    final current = TextEditingController();
    final next = TextEditingController();
    String? error;
    bool busy = false;
    await _sheet<void>(
      icon: Icons.lock_rounded,
      title: 'Change Password',
      subtitle: 'Enter your current password first',
      color: _purple,
      body: (sheet, setSheet) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _field(current, hint: 'Current password', icon: Icons.lock_outline_rounded, obscure: true, autofocus: true),
          const SizedBox(height: 12),
          _field(next, hint: 'New password', icon: Icons.lock_reset_rounded, obscure: true, error: error),
          const SizedBox(height: 16),
          _primaryButton(
            'Save Password',
            () async {
              setSheet(() {
                busy = true;
                error = null;
              });
              try {
                final r = await AdminData.changePassword(current.text, next.text);
                if (r.success) {
                  if (sheet.mounted) Navigator.pop(sheet);
                  _toast('Password changed');
                  return;
                }
                setSheet(() => error = r.message);
              } catch (e) {
                setSheet(() => error = cleanErrorText('$e'));
              }
              setSheet(() => busy = false);
            },
            busy: busy,
            color: _purple,
          ),
        ],
      ),
    );
  }

  /// A parent or guardian agrees to the Terms for a minor's account.
  Future<void> _addGuardian() async {
    final c = TermsConsentController()..minor = true;
    String? error;
    bool busy = false;
    await _sheet<void>(
      icon: Icons.family_restroom_rounded,
      title: 'Parent or Guardian',
      subtitle: 'They read the Terms and agree for you',
      color: _blue,
      body: (sheet, setSheet) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TermsConsentSection(controller: c),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(error!, style: const TextStyle(color: _red, fontSize: 12)),
            ),
          const SizedBox(height: 8),
          _primaryButton(
            'Save consent',
            () async {
              final problem = c.check() ?? (c.guardianGiven ? null : "Fill in your parent or guardian's details.");
              if (problem != null) return setSheet(() => error = problem);
              setSheet(() => busy = true);
              try {
                await Terms.saveGuardianLater(c);
                if (sheet.mounted) Navigator.pop(sheet);
                setState(() => _guardianPending = false);
                _toast('Thank you! Consent saved.');
              } catch (_) {
                setSheet(() {
                  busy = false;
                  error = "Couldn't save. Check your connection.";
                });
              }
            },
            busy: busy,
            color: _blue,
          ),
        ],
      ),
    );
    // Not disposed here: the pop-up is still animating closed and using it; it is freed with the pop-up
  }

  /// Centered dialog like the home screen's welcome message.
  Future<void> _logout() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ts.cardBackground,
        surfaceTintColor: Colors.transparent,
        contentPadding: const EdgeInsets.fromLTRB(24, 28, 24, 8),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: _red.withValues(alpha: 0.12), shape: BoxShape.circle),
              child: const Icon(Icons.logout_rounded, color: _red, size: 34),
            ),
            const SizedBox(height: 14),
            Text(
              'Log out of ResQ?',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: ts.textPrimary),
            ),
            const SizedBox(height: 8),
            Text(
              "You won't get updates about your reports until you log in again.",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, height: 1.45, color: ts.textSecondary),
            ),
          ],
        ),
        actionsPadding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
        actions: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: ts.borderColor),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(
                      'Cancel',
                      style: TextStyle(color: ts.textPrimary, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: _primaryButton('Log out', () => Navigator.pop(ctx, true), color: _red)),
            ],
          ),
        ],
      ),
    );
    if (yes != true) return;
    await SessionService.clearSession();
    if (mounted) Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
  }

  Future<void> _register() async {
    final done = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => GuestRegistrationScreen(userName: '${_profile?['fullName'] ?? ''}')),
    );
    if (done == true) {
      setState(() => _loading = true);
      await _load();
    }
  }

  // ─── layout ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeService.instance,
      builder: (context, _) => Scaffold(
        resizeToAvoidBottomInset: false, // keyboard covers the screen instead of pushing it up
        backgroundColor: ts.pageBackground,
        appBar: AppBar(
          backgroundColor: ts.pageBackground,
          surfaceTintColor: Colors.transparent,
          foregroundColor: ts.textPrimary,
          elevation: 0,
          title: const Text('Settings', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator(color: _orange))
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                children: [
                  _summaryCard(),
                  const SizedBox(height: 24),
                  if (_isGuest) _guestCard() else ..._fullSettings(),
                  const SizedBox(height: 24),
                  _section('About', [
                    _tile(
                      Icons.gavel_rounded,
                      'Terms and Conditions',
                      'Version ${Terms.version} · how ResQ uses your data',
                      onTap: () => openTerms(context),
                      color: _blue,
                    ),
                  ]),
                  const SizedBox(height: 24),
                  _section('Account', [
                    _tile(Icons.logout_rounded, 'Log out', 'Sign out of this phone', onTap: _logout, color: _red),
                  ]),
                  const SizedBox(height: 16),
                  Center(
                    child: ResqText('ResQ · Iriga City', style: TextStyle(fontSize: 12, color: ts.textMuted)),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _summaryCard() {
    final name = '${_profile?['fullName'] ?? 'User'}';
    final phone = '${_profile?['contactNo'] ?? ''}';
    final email = '${_profile?['email'] ?? ''}';
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFF6B00), Color(0xFFFF9248)],
        ),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [BoxShadow(color: _orange.withValues(alpha: 0.3), blurRadius: 18, offset: const Offset(0, 8))],
      ),
      child: Stack(
        children: [
          // Soft circles for depth
          Positioned(right: -30, top: -30, child: _bubble(120)),
          Positioned(right: 40, bottom: -50, child: _bubble(90)),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                GestureDetector(
                  onTap: _isGuest || _uploadingPhoto ? null : _changePhoto,
                  child: Stack(
                    children: [
                      ProfileAvatar(photoUrl: _profile?['photoUrl'] as String?, name: name, radius: 36, light: true),
                      if (_uploadingPhoto)
                        const Positioned.fill(child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3)),
                      if (!_isGuest)
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            padding: const EdgeInsets.all(5),
                            decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                            child: const Icon(Icons.camera_alt_rounded, size: 14, color: _orange),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 6),
                      _summaryLine(Icons.phone_rounded, phone.isEmpty ? 'No phone number' : phone),
                      if (email.isNotEmpty) _summaryLine(Icons.email_rounded, email),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.22),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          _isGuest ? 'Guest account' : 'Citizen',
                          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(double size) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.1), shape: BoxShape.circle),
  );

  Widget _summaryLine(IconData icon, String text) => Padding(
    padding: const EdgeInsets.only(top: 2),
    child: Row(
      children: [
        Icon(icon, size: 14, color: Colors.white70),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
      ],
    ),
  );

  /// Reminder for a minor whose parent hasn't agreed yet. Reporting still works.
  Widget _guardianBanner() => Material(
    color: _blue.withValues(alpha: ts.isDark ? 0.18 : 0.06),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: BorderSide(color: _blue.withValues(alpha: ts.isDark ? 0.7 : 0.35), width: 1.5),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: _addGuardian,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            _chip(Icons.family_restroom_rounded, _blue, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Parent or guardian consent pending',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: ts.textPrimary),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'You can still report anytime. Ask a parent or guardian to agree to unlock all features.',
                    style: TextStyle(fontSize: 12, height: 1.35, color: ts.textSecondary),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: _blue),
          ],
        ),
      ),
    ),
  );

  Widget _guestCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _orange.withValues(alpha: ts.isDark ? 0.15 : 0.06),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _orange.withValues(alpha: 0.35), width: 1.5),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: const BoxDecoration(color: _orange, shape: BoxShape.circle),
            child: const Icon(Icons.lock_person_rounded, size: 30, color: Colors.white),
          ),
          const SizedBox(height: 12),
          Text(
            'Register for more settings',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: ts.textPrimary),
          ),
          const SizedBox(height: 6),
          Text(
            'Create a full account to change your profile picture, name and number, use dark mode and more. '
            'Your reports stay with you.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: ts.textSecondary, height: 1.45),
          ),
          const SizedBox(height: 16),
          SizedBox(width: double.infinity, child: _primaryButton('Register now', _register)),
        ],
      ),
    );
  }

  List<Widget> _fullSettings() => [
    if (_guardianPending) ...[_guardianBanner(), const SizedBox(height: 24)],
    _section('Profile', [
      _tile(Icons.account_circle_rounded, 'Profile picture', 'Take or choose a photo', onTap: _changePhoto),
      _tile(Icons.badge_rounded, 'Name', '${_profile?['fullName'] ?? ''}', onTap: _editName),
      _tile(Icons.phone_rounded, 'Phone number', '${_profile?['contactNo'] ?? ''}', onTap: _editPhone, color: _green),
      _tile(Icons.email_rounded, 'Email', '${_profile?['email'] ?? ''}', color: _blue),
    ]),
    const SizedBox(height: 24),
    _section('Preferences', [
      _switch(Icons.dark_mode_rounded, 'Dark mode', 'Easier on the eyes at night', ts.isDark, (v) {
        final mode = v ? 'Dark' : 'Light';
        ts.setThemeMode(mode);
        _saveSetting({'theme_mode': mode});
      }, color: _purple),
      _switch(
        Icons.map_rounded,
        'Dark map',
        'Map colours on their own, separate from dark mode',
        DisplaySettings.mapDark,
        (v) {
          final mode = v ? 'Dark' : 'Light';
          setState(() => DisplaySettings.mapTheme.value = mode);
          _saveSetting({'map_theme': mode});
        },
        color: _blue,
      ),
      _switch(
        Icons.motion_photos_off_rounded,
        'Minimize animations',
        'No blinking, pulsing, startup animation or screen transitions',
        DisplaySettings.reducedMotion.value,
        (v) {
          setState(() => DisplaySettings.setReducedMotion(v));
          _saveSetting({'reduced_motion': v});
        },
        color: _green,
      ),
      _switch(Icons.volume_up_rounded, 'Alert sounds', 'Play a sound for report updates', _sound, (v) {
        setState(() => _sound = v);
        SoundService.enabled = v;
        _saveSetting({'sound_alerts': v});
      }),
    ]),
    const SizedBox(height: 24),
    _section('Security', [
      _tile(Icons.lock_rounded, 'Change password', 'Keep your account safe', onTap: _changePassword, color: _purple),
    ]),
  ];

  Widget _section(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 14,
                decoration: BoxDecoration(color: _orange, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: ts.textPrimary),
              ),
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: ts.cardBackground,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: ts.borderColor),
            boxShadow: [BoxShadow(color: ts.shadowColor, blurRadius: 10, offset: const Offset(0, 3))],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) Divider(height: 1, indent: 64, color: ts.borderColor),
                children[i],
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _tile(IconData icon, String title, String subtitle, {VoidCallback? onTap, Color color = _orange}) {
    final danger = color == _red;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      leading: _chip(icon, color),
      title: Text(
        title,
        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: danger ? _red : ts.textPrimary),
      ),
      subtitle: subtitle.isEmpty
          ? null
          : Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: ts.textSecondary),
            ),
      trailing: onTap == null || danger ? null : Icon(Icons.chevron_right_rounded, color: ts.textMuted),
      onTap: onTap,
    );
  }

  Widget _switch(
    IconData icon,
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> onChanged, {
    Color color = _orange,
  }) {
    return SwitchListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      secondary: _chip(icon, color),
      title: Text(
        title,
        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: ts.textPrimary),
      ),
      subtitle: Text(subtitle, style: TextStyle(fontSize: 13, color: ts.textSecondary)),
      value: value,
      activeThumbColor: Colors.white,
      activeTrackColor: _orange,
      onChanged: onChanged,
    );
  }
}

/// The user's profile picture, or their initial on an orange circle.
class ProfileAvatar extends StatelessWidget {
  final String? photoUrl;
  final String name;
  final double radius;

  /// White ring, for use on the orange summary card.
  final bool light;

  const ProfileAvatar({super.key, this.photoUrl, required this.name, this.radius = 20, this.light = false});

  @override
  Widget build(BuildContext context) {
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    final hasPhoto = photoUrl != null && photoUrl!.isNotEmpty;
    return Container(
      padding: EdgeInsets.all(light ? 3 : 0),
      decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
      child: CircleAvatar(
        radius: radius,
        backgroundColor: const Color(0xFFFF6B00),
        backgroundImage: hasPhoto ? NetworkImage(photoUrl!) : null,
        child: hasPhoto
            ? null
            : Text(
                initial,
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: radius * 0.8),
              ),
      ),
    );
  }
}
