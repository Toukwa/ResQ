import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'login.dart';
import 'citizen/home_screen.dart';
import 'superadmin/super_admin_shell.dart';
import 'admin/admin_shell.dart';
import 'services/firebase_rest.dart';
import 'services/session_service.dart';
import 'services/theme_service.dart';
import 'shared/resq_logo.dart';
import 'shared/role_home.dart';
import 'shared/search_shortcut.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final originalOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    if (details.stack.toString().contains('raw_keyboard.dart') ||
        details.exception.toString().contains('keysPressed.isNotEmpty')) {
      // Suppress Windows RawKeyboard framework assertion bug during Alt/Tab key transitions
      return;
    }
    if (originalOnError != null) {
      originalOnError(details);
    } else {
      FlutterError.presentError(details);
    }
  };

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    HardwareKeyboard.instance.addHandler(_desktopShortcuts);
  }

  runApp(const MyApp());
}

/// Windows: F11 toggles full screen (Esc leaves it); Ctrl+F jumps to the screen's search box.
bool _desktopShortcuts(KeyEvent event) {
  if (event is! KeyDownEvent) return false;
  final key = event.logicalKey;
  if (key == LogicalKeyboardKey.f11) {
    _DesktopFullScreen.toggle();
    return true;
  }
  if (key == LogicalKeyboardKey.keyF && HardwareKeyboard.instance.isControlPressed) {
    return SearchShortcut.focusVisible();
  }
  if (key == LogicalKeyboardKey.escape && _DesktopFullScreen.on) _DesktopFullScreen.toggle();
  return false; // Esc still closes dialogs as usual
}

/// Full screen on Windows, done by the runner (windows/runner/flutter_window.cpp):
/// a borderless window covering exactly the monitor it is on, over the taskbar.
/// window_manager's setFullScreen and a hidden title bar both left the window
/// off by its invisible resize borders, with the taskbar still on top.
class _DesktopFullScreen {
  static const _channel = MethodChannel('resq/fullscreen');
  static bool on = false;
  static bool _busy = false;

  static Future<void> toggle() async {
    if (_busy) return;
    _busy = true;
    try {
      on = await _channel.invokeMethod<bool>('set', !on) ?? on;
    } finally {
      _busy = false;
    }
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeService.instance,
      builder: (context, _) {
        final isDark = ThemeService.instance.isDark;
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'ResQ',
          themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
          theme: ThemeData(
            fontFamily: 'Inter',
            brightness: Brightness.light,
            scaffoldBackgroundColor: const Color(0xFFF4F3F0),
            cardColor: Colors.white,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFFF5C00),
              brightness: Brightness.light,
              surface: const Color(0xFFF4F3F0),
            ),
          ),
          darkTheme: ThemeData(
            fontFamily: 'Inter',
            brightness: Brightness.dark,
            scaffoldBackgroundColor: const Color(0xFF111827),
            cardColor: const Color(0xFF1F2937),
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFFF5C00),
              brightness: Brightness.dark,
              surface: const Color(0xFF1F2937),
            ),
          ),
          home: const SessionInitializer(),
          routes: {
            '/login': (context) => const LoginScreen(),
          },
        );
      },
    );
  }
}

class SessionInitializer extends StatefulWidget {
  const SessionInitializer({super.key});

  @override
  State<SessionInitializer> createState() => _SessionInitializerState();
}

/// Intro screen: shows the logo and name while the saved login is checked,
/// for at least [_minimumDisplay], then fades into the right screen.
class _SessionInitializerState extends State<SessionInitializer> with SingleTickerProviderStateMixin {
  static const _minimumDisplay = Duration(milliseconds: 2200);

  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..forward();

  @override
  void initState() {
    super.initState();
    _checkSession();
  }

  @override
  void dispose() {
    _intro.dispose();
    super.dispose();
  }

  /// Replaces the intro with [screen] using a fade.
  void _go(Widget screen) {
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 500),
        pageBuilder: (_, _, _) => screen,
        transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  Future<void> _checkSession() async {
    final shownLongEnough = Future.delayed(_minimumDisplay);
    var session = await SessionService.getSession();
    // A saved session is only usable if the Firebase login can be restored too
    if (session != null && await FirebaseAuthRest.restore() == null) {
      await SessionService.clearSession();
      session = null;
    }
    await shownLongEnough;

    if (!mounted) return;

    if (session != null) {
      final userId = session['id'] as int;
      final role = session['role'] as String;
      final fullName = session['fullName'] as String;

      final home = homeForRole(role);
      if (home == RoleHome.superAdmin) {
        _go(SuperAdminShell(
              isSuperAdmin: true,
              userId: userId,
            ));
      } else if (home == RoleHome.admin) {
        _go(AdminShell(
              userId: userId,
            ));
      } else {
        _go(HomeScreen(
              citizenId: userId.toString(),
              userName: fullName,
            ));
      }
    } else {
      _go(const LoginScreen());
    }
  }

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    final fade = CurvedAnimation(parent: _intro, curve: Curves.easeOut);
    return Scaffold(
      resizeToAvoidBottomInset: false, // keyboard covers the screen instead of pushing it up
      backgroundColor: ts.pageBackground,
      body: Center(
        child: FadeTransition(
          opacity: fade,
          child: ScaleTransition(
            scale: Tween(begin: 0.85, end: 1.0).animate(fade),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ResqLogo(size: 140, radius: 32),
                const SizedBox(height: 20),
                Text(
                  'ResQ',
                  style: TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                    color: ts.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Emergency Response Portal',
                  style: TextStyle(fontSize: 14, color: ts.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
