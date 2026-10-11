import 'package:flutter/material.dart';
import '../services/session_service.dart';
import '../shared/resq_logo.dart';
import 'citizen_alerts.dart';

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
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            if (showBackButton)
              Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: IconButton(
                  icon: const Icon(
                    Icons.arrow_back_ios_new_rounded,
                    color: Color(0xFF1E293B),
                    size: 20,
                  ),
                  onPressed: onBackPressed ?? () => Navigator.of(context).pop(),
                ),
              ),
            const ResqLogo(size: 44, radius: 12),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Hello, $userName 👋",
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1E293B),
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: textSecondary,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
        Row(
          children: [
            const CitizenAlertsBell(),
            const SizedBox(width: 10),
            _AccountButton(userName: userName),
          ],
        ),
      ],
    );
  }
}


/// Round avatar with the user's initial. Opens a small menu with their name,
/// email and Log out, so logging out takes a deliberate extra step.
class _AccountButton extends StatefulWidget {
  final String userName;
  const _AccountButton({required this.userName});

  @override
  State<_AccountButton> createState() => _AccountButtonState();
}

class _AccountButtonState extends State<_AccountButton> {
  static const _red = Color(0xFFEF4444);
  String _email = '';

  @override
  void initState() {
    super.initState();
    SessionService.getSession().then((s) {
      if (mounted) setState(() => _email = (s?['email'] ?? '').toString());
    });
  }

  String get _initial {
    final name = widget.userName.trim();
    return name.isEmpty ? '?' : name[0].toUpperCase();
  }

  Future<void> _confirmLogout() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
            const Expanded(
              child: Text(
                'Log out of ResQ?',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Color(0xFF0F172A)),
              ),
            ),
          ],
        ),
        content: const Text(
          "You won't get updates about your reports until you log in again.",
          style: TextStyle(fontSize: 13, color: Color(0xFF475569), height: 1.4),
        ),
        actions: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    side: const BorderSide(color: Color(0xFFE2E8F0)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: const Text('Cancel',
                      style: TextStyle(color: Color(0xFF0F172A), fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
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

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Account',
      offset: const Offset(0, 52),
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      onSelected: (v) {
        if (v == 'logout') _confirmLogout();
      },
      itemBuilder: (_) => [
        PopupMenuItem<String>(
          enabled: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.userName,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF0F172A))),
              Text(_email.isEmpty ? 'Guest account' : _email,
                  style: const TextStyle(fontSize: 12, color: CitizenHeader.textSecondary)),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: 'logout',
          child: Row(
            children: [
              Icon(Icons.logout_rounded, color: _red, size: 20),
              SizedBox(width: 10),
              Text('Log out', style: TextStyle(color: _red, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ],
      child: CircleAvatar(
        backgroundColor: CitizenHeader.brandOrange,
        child: Text(
          _initial,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
        ),
      ),
    );
  }
}
