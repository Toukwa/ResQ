import 'package:flutter/material.dart';
import '../services/firebase_rest.dart';
import '../services/theme_service.dart';
import '../shared/resq_logo.dart';
import 'citizen_alerts.dart';
import 'citizen_settings_screen.dart';

class CitizenHeader extends StatelessWidget {
  final String userName;
  final String subtitle;
  final bool showBackButton;
  final VoidCallback? onBackPressed;

  /// Just the logo and the bell (report status screen): no greeting or account button.
  final bool minimal;

  const CitizenHeader({
    super.key,
    required this.userName,
    this.subtitle = "Stay safe",
    this.showBackButton = false,
    this.onBackPressed,
    this.minimal = false,
  });

  static const Color brandOrange = Color(0xFFFF6B00);
  static const Color textSecondary = Color(0xFF94A3B8);

  @override
  Widget build(BuildContext context) {
    if (minimal) {
      return const Row(
        children: [ResqLogo(size: 40, radius: 12), Spacer(), CitizenAlertsBell()],
      );
    }
    // Logo, bell and the profile picture only: long names no longer push the
    // buttons off small screens. The name lives on the Settings screen.
    return Row(
      children: [
        if (showBackButton)
          IconButton(
            icon: Icon(Icons.arrow_back_ios_new_rounded, color: ThemeService.instance.textPrimary, size: 20),
            onPressed: onBackPressed ?? () => Navigator.of(context).pop(),
          ),
        const ResqLogo(size: 44, radius: 12),
        const Spacer(),
        const CitizenAlertsBell(),
        const SizedBox(width: 10),
        _AccountButton(userName: userName),
      ],
    );
  }
}

/// The user's profile picture; opens the Settings screen.
class _AccountButton extends StatefulWidget {
  final String userName;
  const _AccountButton({required this.userName});

  @override
  State<_AccountButton> createState() => _AccountButtonState();
}

class _AccountButtonState extends State<_AccountButton> {
  String? _photoUrl;

  @override
  void initState() {
    super.initState();
    _loadPhoto();
  }

  Future<void> _loadPhoto() async {
    try {
      final url = await Rtdb.get('users/${FirebaseAuthRest.uid}/photoUrl');
      if (mounted) setState(() => _photoUrl = url as String?);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Settings',
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CitizenSettingsScreen()));
          _loadPhoto();
        },
        child: ProfileAvatar(photoUrl: _photoUrl, name: widget.userName),
      ),
    );
  }
}
