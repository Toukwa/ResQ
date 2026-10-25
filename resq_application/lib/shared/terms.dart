import 'package:flutter/material.dart';

import '../services/firebase_rest.dart';
import '../services/theme_service.dart';
import 'resq_text.dart';

/// ResQ Terms and Conditions: the text, the "I agree" checkbox (with a parent or
/// guardian's consent for users under 18), and where acceptance is saved.
///
/// Raise [Terms.version] whenever the text changes: everyone is asked to accept again.
class Terms {
  static const version = 1;
  static const updated = 'October 18, 2026';
  static const adultAge = 18;

  static bool isMinor(DateTime birthdate) {
    final now = DateTime.now();
    var age = now.year - birthdate.year;
    if (now.month < birthdate.month || (now.month == birthdate.month && now.day < birthdate.day)) age--;
    return age < adultAge;
  }

  /// True if the signed-in user accepted the current version.
  static Future<bool> accepted() async {
    try {
      final v = await Rtdb.get('user_settings/${FirebaseAuthRest.uid}/terms_version');
      return v is int && v >= version;
    } catch (_) {
      return true; // offline: don't lock people out of an emergency app
    }
  }

  /// Saves who accepted, when, and (for minors) the consenting parent or guardian.
  static Future<void> saveAcceptance(TermsConsentController c) async {
    final uid = FirebaseAuthRest.uid;
    await Rtdb.update('user_settings/$uid', {
      'terms_version': version,
      'terms_accepted_at': {'.sv': 'timestamp'},
      if (c.guardianGiven)
        'guardian_consent': {
          'name': c.guardianName.text.trim(),
          'contactNo': c.guardianContact.text.trim(),
          'relationship': c.relationship,
          'givenAt': {'.sv': 'timestamp'},
        },
    });
    // On the profile too, so admins can see which minors still need a parent's consent
    await setGuardianPending(c.minor && !c.guardianGiven);
  }

  static Future<void> setGuardianPending(bool pending) =>
      Rtdb.update('users/${FirebaseAuthRest.uid}', {'guardianPending': pending ? true : null});

  /// True if the signed-in user is a minor whose parent hasn't agreed yet.
  static Future<bool> guardianPending() async {
    try {
      return await Rtdb.get('users/${FirebaseAuthRest.uid}/guardianPending') == true;
    } catch (_) {
      return false;
    }
  }

  /// Settings: a parent agrees later.
  static Future<void> saveGuardianLater(TermsConsentController c) async {
    await Rtdb.update('user_settings/${FirebaseAuthRest.uid}', {
      'guardian_consent': {
        'name': c.guardianName.text.trim(),
        'contactNo': c.guardianContact.text.trim(),
        'relationship': c.relationship,
        'givenAt': {'.sv': 'timestamp'},
      },
    });
    await setGuardianPending(false);
  }

  // ─── the text (DRAFT: have it reviewed before release) ─────────────────

  static const sections = <(String, String)>[
    (
      '1. About ResQ',
      'ResQ is an emergency reporting app for Iriga City, Camarines Sur. It lets residents send emergency '
          'reports with their location, photos, videos and voice messages to the City Emergency Operations '
          'Center (EOC) and partner agencies: the Bureau of Fire Protection (BFP), the Philippine National '
          'Police (PNP) and the City Disaster Risk Reduction and Management Office (CDRRMO). By creating an '
          'account or sending a report, you agree to these Terms.',
    ),
    (
      '2. Not a replacement for emergency hotlines',
      'ResQ helps you reach responders, but it depends on your phone, internet connection and GPS. Reports '
          'can be delayed or fail to send. In a life-threatening emergency, also call 911 or the agency '
          'hotlines shown in the app. ResQ does not guarantee that responders will arrive within any set time.',
    ),
    (
      '3. Who may use ResQ',
      'Anyone, of any age, may send an emergency report. Reporting is never blocked because of age.\n\n'
          'If you are below 18, a parent or legal guardian should read these Terms and agree on your behalf. '
          'You may create an account and report right away; until a parent or guardian agrees, your account is '
          'marked "guardian consent pending" and you will be reminded to add their details in Settings. '
          'Reporting, location sharing and alerts always work. Some extra features, such as changing your profile '
          'picture, are available once a parent or guardian has agreed.\n\n'
          'Under the Data Privacy Act of 2012, personal information may be processed without consent when it is '
          'needed to protect the life and health of a person. Information in emergency reports, including those '
          'sent by minors, is processed on this basis.',
    ),
    (
      '4. Your account',
      'Give your real name, phone number, birthdate and barangay, and keep them up to date so responders '
          'can reach you. Keep your password private. You are responsible for reports sent from your account. '
          'Tell us right away if you think someone else is using it.',
    ),
    (
      '5. Truthful reports only',
      'Only report real emergencies, and describe them honestly. False, prank or joke reports take '
          'responders away from people who truly need help. When a report is marked as a prank, ResQ shows '
          'you a warning and records your device\'s IP address, your account details and the report in the '
          'system logs. Repeated or serious false reports may lead to your account being disabled and may be '
          'reported to authorities. Knowingly giving false alarms may be punishable under Philippine law, '
          'including Presidential Decree No. 1727 and Republic Act No. 10175 where it applies.',
    ),
    (
      '6. What we collect',
      'To handle your reports, ResQ collects:\n'
          '• Account details: name, email, phone number, birthdate, barangay and profile picture.\n'
          '• Location: your GPS position while the app is open and while a report is active, and the '
          'location pinned on each report.\n'
          '• Report contents: incident type, notes, photos, videos and voice messages.\n'
          '• Device details: device model, approximate location from your internet connection (shown in '
          'login code emails) and IP address (for prank warnings).\n'
          '• Activity: logins and actions in the app, kept in system logs.\n'
          '• For users below 18: the name, relationship and phone number of the consenting parent or guardian.',
    ),
    (
      '7. How we use and share it',
      'Your information is used only to receive, route and respond to emergencies, to contact you about '
          'your reports, to keep accounts secure, and to prevent misuse. Report details and your location are '
          'shared with the EOC and the agencies and response units assigned to your report. We do not sell '
          'your information or use it for advertising. Information may be disclosed when required by law or '
          'a lawful order.',
    ),
    (
      '8. Your privacy rights',
      'ResQ handles personal information under the Data Privacy Act of 2012 (Republic Act No. 10173). '
          'You have the right to be informed, to access your information, to correct it, to object, to ask '
          'for it to be erased or blocked, and to file a complaint with the National Privacy Commission. '
          'Reports already sent may be kept as official emergency records even after your account is deleted. '
          'To use these rights, contact the ResQ administrators through the Iriga City EOC.',
    ),
    (
      '9. Storage and security',
      'Information is stored on Google Firebase and Cloudinary servers and protected by access rules so '
          'that only you and authorized staff can see it. No system is completely secure, but we take '
          'reasonable steps to protect your information. Login codes are sent to your email for new devices '
          'and after 7 days without logging in.',
    ),
    (
      '10. Permissions',
      'ResQ asks for your location, camera and microphone so you can send reports with evidence. You can '
          'turn these off in your phone settings, but reporting may not work fully without them.',
    ),
    (
      '11. Changes and contact',
      'We may update these Terms. When we do, the app will ask you to read and accept the new version '
          'before continuing. For questions, contact the ResQ administrators through the Iriga City Emergency '
          'Operations Center.',
    ),
  ];
}

/// Holds the agreement state for [TermsConsentSection].
class TermsConsentController extends ChangeNotifier {
  bool agreed = false;
  bool guardianAgreed = false;
  bool minor = false;
  String relationship = 'Parent';
  final guardianName = TextEditingController();
  final guardianContact = TextEditingController();

  /// Changes a value and redraws the section.
  void update(VoidCallback change) {
    change();
    notifyListeners();
  }

  void setMinor(bool v) {
    if (minor == v) return;
    minor = v;
    notifyListeners();
  }

  /// A short reason why the user can't continue yet, or null when everything is filled in.
  /// Minors may skip the guardian part: it never blocks signing up or reporting,
  /// the account is just marked "consent pending" until a parent agrees.
  bool get guardianStarted =>
      guardianName.text.trim().isNotEmpty || guardianContact.text.trim().isNotEmpty || guardianAgreed;
  bool get guardianGiven => minor && guardianStarted && _guardianProblem() == null;

  String? check() {
    if (!agreed) return 'Please read and agree to the Terms and Conditions.';
    if (!minor || !guardianStarted) return null;
    return _guardianProblem();
  }

  String? _guardianProblem() {
    if (guardianName.text.trim().length < 3) return "Enter your parent or guardian's full name.";
    if (!RegExp(r'^(09|\+639)\d{9}$').hasMatch(guardianContact.text.trim())) {
      return "Enter your parent or guardian's phone number (09XXXXXXXXX).";
    }
    if (!guardianAgreed) return 'Your parent or guardian must agree to the Terms.';
    return null;
  }

  @override
  void dispose() {
    guardianName.dispose();
    guardianContact.dispose();
    super.dispose();
  }
}

/// "I have read and agree" checkbox, plus parent/guardian consent for users under 18.
class TermsConsentSection extends StatelessWidget {
  final TermsConsentController controller;
  const TermsConsentSection({super.key, required this.controller});

  static const _orange = Color(0xFFFF6B00);
  static const _blue = Color(0xFF2563EB);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final ts = ThemeService.instance;
        final c = controller;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              child: !c.minor
                  ? const SizedBox(width: double.infinity)
                  : Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: _blue.withValues(alpha: ts.isDark ? 0.18 : 0.06),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: _blue.withValues(alpha: ts.isDark ? 0.7 : 0.35)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.family_restroom_rounded, color: _blue, size: 20),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Parent or guardian consent (can be added later)',
                                  style: TextStyle(fontWeight: FontWeight.bold, color: ts.textPrimary),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'You are under 18, so a parent or guardian should read the Terms and agree for you. '
                            'Not with them right now? Leave this empty: you can still sign up and report, '
                            'and add their details later in Settings.',
                            style: TextStyle(fontSize: 12, height: 1.4, color: ts.textSecondary),
                          ),
                          const SizedBox(height: 12),
                          _input(
                            ts,
                            c.guardianName,
                            'Parent/guardian full name',
                            Icons.person_outline_rounded,
                            TextInputType.name,
                          ),
                          const SizedBox(height: 8),
                          _input(
                            ts,
                            c.guardianContact,
                            'Parent/guardian phone (09XXXXXXXXX)',
                            Icons.phone_outlined,
                            TextInputType.phone,
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            children: [
                              for (final r in ['Parent', 'Guardian'])
                                ChoiceChip(
                                  label: Text(r),
                                  selected: c.relationship == r,
                                  selectedColor: _blue.withValues(alpha: 0.15),
                                  labelStyle: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: c.relationship == r ? _blue : ts.textSecondary,
                                  ),
                                  side: BorderSide(color: c.relationship == r ? _blue : ts.borderColor),
                                  onSelected: (_) => c.update(() => c.relationship = r),
                                ),
                            ],
                          ),
                          _checkRow(
                            ts,
                            value: c.guardianAgreed,
                            color: _blue,
                            onChanged: (v) => c.update(() => c.guardianAgreed = v),
                            text: [
                              const TextSpan(text: 'I am the parent or guardian. I have read the '),
                              _link(context, color: _blue),
                              const TextSpan(text: ' and allow this child to use ResQ.'),
                            ],
                          ),
                        ],
                      ),
                    ),
            ),
            _checkRow(
              ts,
              value: c.agreed,
              color: _orange,
              onChanged: (v) => c.update(() => c.agreed = v),
              text: [
                const TextSpan(text: 'I have read and agree to the '),
                _link(context, color: _orange),
                const TextSpan(text: ', including the use of my location and reports.'),
              ],
            ),
          ],
        );
      },
    );
  }

  /// Tapping the words opens the full Terms (the rest of the row ticks the box).
  static InlineSpan _link(BuildContext context, {required Color color}) => WidgetSpan(
    alignment: PlaceholderAlignment.baseline,
    baseline: TextBaseline.alphabetic,
    child: GestureDetector(
      onTap: () => openTerms(context),
      child: Text(
        'Terms and Conditions',
        style: TextStyle(
          fontSize: 13,
          height: 1.4,
          color: color,
          fontWeight: FontWeight.bold,
          decoration: TextDecoration.underline,
          decorationColor: color,
        ),
      ),
    ),
  );

  Widget _input(ThemeService ts, TextEditingController c, String hint, IconData icon, TextInputType type) => TextField(
    controller: c,
    keyboardType: type,
    style: TextStyle(color: ts.textPrimary, fontSize: 14),
    decoration: InputDecoration(
      isDense: true,
      hintText: hint,
      hintStyle: TextStyle(color: ts.textMuted, fontSize: 13),
      prefixIcon: Icon(icon, size: 18, color: ts.textMuted),
      filled: true,
      fillColor: ts.cardBackground,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: ts.borderColor),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _blue),
      ),
    ),
  );

  Widget _checkRow(
    ThemeService ts, {
    required bool value,
    required Color color,
    required ValueChanged<bool> onChanged,
    required List<InlineSpan> text,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                value: value,
                activeColor: color,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: (v) => onChanged(v ?? false),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text.rich(
                TextSpan(
                  style: TextStyle(fontSize: 13, height: 1.4, color: ts.textSecondary),
                  children: text,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens the full Terms and Conditions.
Future<void> openTerms(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TermsScreen()));

class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    return Scaffold(
      backgroundColor: ts.pageBackground,
      appBar: AppBar(
        backgroundColor: ts.pageBackground,
        surfaceTintColor: Colors.transparent,
        foregroundColor: ts.textPrimary,
        elevation: 0,
        title: const Text('Terms and Conditions', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          Text(
            'Version ${Terms.version} · Last updated ${Terms.updated}',
            style: TextStyle(fontSize: 12, color: ts.textMuted),
          ),
          const SizedBox(height: 12),
          for (final (title, body) in Terms.sections)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: ts.cardBackground,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: ts.borderColor),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: ts.textPrimary),
                  ),
                  const SizedBox(height: 6),
                  ResqText(body, style: TextStyle(fontSize: 13.5, height: 1.5, color: ts.textSecondary)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// One-time pop-up for accounts that never saw the sign-up checkbox (Google sign-up,
/// older accounts) or when the Terms change. Returns true once accepted.
Future<bool> showTermsAcceptanceDialog(BuildContext context, {DateTime? birthdate}) async {
  final c = TermsConsentController()..minor = birthdate != null && Terms.isMinor(birthdate);
  String? error;
  bool busy = false;
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) {
        final ts = ThemeService.instance;
        return AlertDialog(
          backgroundColor: ts.cardBackground,
          surfaceTintColor: Colors.transparent,
          contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF6B00).withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.gavel_rounded, color: Color(0xFFFF6B00), size: 32),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  Terms.version > 1 ? 'Our Terms have been updated' : 'Before you continue',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: ts.textPrimary),
                ),
                const SizedBox(height: 6),
                Text(
                  'Please read and accept the ResQ Terms and Conditions to keep using the app.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, height: 1.4, color: ts.textSecondary),
                ),
                const SizedBox(height: 14),
                TermsConsentSection(controller: c),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(error!, style: const TextStyle(color: Color(0xFFEF4444), fontSize: 12)),
                  ),
              ],
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
          actions: [
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: OutlinedButton(
                      onPressed: busy ? null : () => Navigator.pop(ctx, false),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: ts.borderColor),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text(
                        'Log out',
                        style: TextStyle(color: ts.textPrimary, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: ElevatedButton(
                      onPressed: busy
                          ? null
                          : () async {
                              final problem = c.check();
                              if (problem != null) return setD(() => error = problem);
                              setD(() {
                                busy = true;
                                error = null;
                              });
                              try {
                                await Terms.saveAcceptance(c);
                                if (ctx.mounted) Navigator.pop(ctx, true);
                              } catch (_) {
                                setD(() {
                                  busy = false;
                                  error = "Couldn't save. Check your connection and try again.";
                                });
                              }
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFF6B00),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('I agree', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    ),
  );
  // Not disposed here: the pop-up is still animating closed and using it; it is freed with the pop-up
  return ok == true;
}
