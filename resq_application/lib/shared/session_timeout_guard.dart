import 'dart:async';
import 'package:flutter/material.dart';
import '../admin/admin_service.dart';
import '../services/session_service.dart';

/// Logs the user out after a period of no mouse / touch activity, following
/// their "Auto Logout" and "Session Timeout" settings (re-read every 10 s so
/// changes in Settings apply without restarting).
class SessionTimeoutGuard extends StatefulWidget {
  final int userId;
  final Widget child;
  const SessionTimeoutGuard({super.key, required this.userId, required this.child});

  static Duration parseTimeout(String? value) {
    final s = (value ?? '').toLowerCase().trim();
    if (s.contains('30 sec')) return const Duration(seconds: 30);
    if (s.contains('1 min')) return const Duration(minutes: 1);
    if (s.contains('5 min')) return const Duration(minutes: 5);
    if (s.contains('30 min')) return const Duration(minutes: 30);
    if (s.contains('1 hour') || s.contains('1 hr')) return const Duration(hours: 1);
    if (s.contains('2 hour') || s.contains('2 hr')) return const Duration(hours: 2);
    return const Duration(minutes: 15);
  }

  @override
  State<SessionTimeoutGuard> createState() => _SessionTimeoutGuardState();
}

class _SessionTimeoutGuardState extends State<SessionTimeoutGuard> {
  Timer? _idleTimer;
  Timer? _settingsTimer;
  bool _enabled = true;
  Duration _timeout = const Duration(minutes: 15);
  DateTime _lastActivity = DateTime.now();
  bool _loggingOut = false;

  @override
  void initState() {
    super.initState();
    _restart();
    _loadSettings();
    _settingsTimer = Timer.periodic(const Duration(seconds: 10), (_) => _loadSettings());
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _settingsTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    try {
      final s = await AdminService.getUserSettings(widget.userId);
      if (s == null) return;
      final enabled = '${s['auto_logout']}' != '0' && s['auto_logout'] != false;
      final timeout = SessionTimeoutGuard.parseTimeout(s['session_timeout']?.toString());
      if (enabled != _enabled || timeout != _timeout) {
        _enabled = enabled;
        _timeout = timeout;
        _restart();
      }
    } catch (_) {} // keep the current timer if settings can't be read
  }

  void _restart() {
    _idleTimer?.cancel();
    if (_enabled && !_loggingOut) _idleTimer = Timer(_timeout, _expire);
  }

  void _onActivity() {
    final now = DateTime.now();
    if (now.difference(_lastActivity) < const Duration(seconds: 1)) return;
    _lastActivity = now;
    _restart();
  }

  String get _timeoutText {
    if (_timeout.inSeconds < 60) return '${_timeout.inSeconds} seconds';
    if (_timeout.inMinutes < 60) return '${_timeout.inMinutes} minute${_timeout.inMinutes > 1 ? 's' : ''}';
    return '${_timeout.inHours} hour${_timeout.inHours > 1 ? 's' : ''}';
  }

  Future<void> _expire() async {
    if (!mounted || _loggingOut) return;
    _loggingOut = true;
    await SessionService.clearSession(); // sign out now, even if the dialog is never answered
    if (!mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(children: [
          Icon(Icons.timer_off_outlined, color: Color(0xFFEF4444), size: 28),
          SizedBox(width: 10),
          Text('Session Expired', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        ]),
        content: Text('You have been automatically logged out due to inactivity ($_timeoutText).\n\n'
            'Please log in again to continue.'),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Return to Login'),
          ),
        ],
      ),
    );
    if (mounted) Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
  }

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _onActivity(),
        onPointerMove: (_) => _onActivity(),
        onPointerHover: (_) => _onActivity(),
        child: widget.child,
      );
}
