import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../admin/admin_service.dart';
import '../services/firebase_rest.dart';
import '../services/session_service.dart';
import 'resq_dialog.dart';

/// Logs staff out after a period of no mouse, touch or keyboard activity, following
/// their "Auto Logout" and "Session Timeout" settings (re-read every 30 s so changes
/// in Settings apply without restarting). A one-minute warning comes first, so a
/// screen left up to watch for reports isn't closed without asking. An account the
/// EOC removed is signed out at the next check.
class SessionTimeoutGuard extends StatefulWidget {
  final int userId;
  final Widget child;

  const SessionTimeoutGuard({super.key, required this.userId, required this.child});

  /// How long the warning waits for an answer before logging out.
  static const warningTime = Duration(minutes: 1);

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
  bool _warning = false;
  bool _loggingOut = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    _restart();
    _loadSettings();
    _settingsTimer = Timer.periodic(const Duration(seconds: 30), (_) => _loadSettings());
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _idleTimer?.cancel();
    _settingsTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    try {
      // Removed by the EOC: sign out now instead of at the next login
      if (await Rtdb.get('users/${FirebaseAuthRest.uid}/disabled') == true) {
        _logOut('This account has been removed by the EOC.');
        return;
      }
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
    if (_enabled && !_loggingOut && !_warning) _idleTimer = Timer(_timeout, _warn);
  }

  bool _onKey(KeyEvent event) {
    _onActivity();
    return false; // never swallow the key
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

  /// Asks first; logs out if nobody answers within [SessionTimeoutGuard.warningTime].
  Future<void> _warn() async {
    if (!mounted || _loggingOut || _warning) return;
    _warning = true;
    final navigator = Navigator.of(context);
    final noAnswer = Timer(SessionTimeoutGuard.warningTime, () {
      if (navigator.canPop()) navigator.pop(false);
    });
    final stay = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => ResqDialog(
        icon: Icons.timer_outlined,
        color: const Color(0xFFD97706),
        title: 'Still there?',
        subtitle: 'No activity for $_timeoutText',
        cancelLabel: 'Log out now',
        primaryLabel: 'Stay signed in',
        primaryIcon: Icons.check_rounded,
        onPrimary: () => Navigator.of(ctx).pop(true),
        child: const Text('You will be logged out in 1 minute unless you choose to stay signed in.'),
      ),
    );
    noAnswer.cancel();
    _warning = false;
    if (stay == true) {
      _lastActivity = DateTime.now();
      _restart();
    } else {
      _logOut('You have been logged out due to inactivity ($_timeoutText).');
    }
  }

  Future<void> _logOut(String reason) async {
    if (!mounted || _loggingOut) return;
    _loggingOut = true;
    _idleTimer?.cancel();
    await SessionService.clearSession(); // sign out now, even if the pop-up is never answered
    if (!mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => ResqDialog(
        icon: Icons.timer_off_outlined,
        color: const Color(0xFFEF4444),
        title: 'Session Ended',
        cancelLabel: 'Return to Login',
        child: Text('$reason\n\nPlease log in again to continue.'),
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
        onPointerSignal: (_) => _onActivity(),
        child: widget.child,
      );
}
