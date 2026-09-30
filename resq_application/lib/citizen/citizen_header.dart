import 'package:flutter/material.dart';
import '../services/session_service.dart';
import '../shared/resq_logo.dart';

class CitizenHeader extends StatelessWidget {
  final String userName;
  final String subtitle;
  final bool showBackButton;
  final VoidCallback? onBackPressed;

  const CitizenHeader({
    super.key,
    required this.userName,
    this.subtitle = "Stay safe",
    this.showBackButton = false,
    this.onBackPressed,
  });

  static const Color brandOrange = Color(0xFFFF6B00);
  static const Color textSecondary = Color(0xFF94A3B8);

  @override
  Widget build(BuildContext context) {
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
            IconButton(
              icon: const Icon(
                Icons.logout,
                color: Color(0xFFEF4444),
              ),
              onPressed: () async {
                await SessionService.clearSession();
                if (context.mounted) {
                  Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
                }
              },
            ),
            const SizedBox(width: 8),
            const CircleAvatar(
              backgroundColor: Colors.white,
              child: Icon(
                Icons.notifications_none_outlined,
                color: Color(0xFFFF6B00),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
