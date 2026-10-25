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
import 'shared/display_settings.dart';
import 'shared/resq_text.dart';
import 'shared/splash_siren.dart';
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

  await ThemeService.instance.load();
  await DisplaySettings.loadDeviceSettings();
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

  /// Every pop-up gets the ResqDialog look (rounded bordered card, bold title),
  /// including the forms still built on the plain AlertDialog.
  static DialogThemeData _dialogTheme({required bool dark}) => DialogThemeData(
        backgroundColor: dark ? const Color(0xFF1F2937) : Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: dark ? const Color(0xFF374151) : const Color(0xFFE2E8F0)),
        ),
        titleTextStyle: TextStyle(
          fontFamily: 'Inter',
          fontSize: 16,
          fontWeight: FontWeight.w800,
          color: dark ? const Color(0xFFF9FAFB) : const Color(0xFF0F172A),
        ),
      );

  /// Screens switch at once when animations are minimized.
  static final _noTransitions = PageTransitionsTheme(builders: {
    for (final p in TargetPlatform.values) p: _NoTransition(),
  });

  static final _textButtonTheme = TextButtonThemeData(
    style: TextButton.styleFrom(
      foregroundColor: const Color(0xFF64748B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([ThemeService.instance, DisplaySettings.reducedMotion]),
      builder: (context, _) {
        final isDark = ThemeService.instance.isDark;
        final still = DisplaySettings.reducedMotion.value;
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'ResQ',
          themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
          // Minimize animations: no theme fade, and every screen below sees disableAnimations
          themeAnimationDuration: still ? Duration.zero : kThemeAnimationDuration,
          builder: (context, child) {
            final mq = MediaQuery.of(context);
            return MediaQuery(data: mq.copyWith(disableAnimations: still || mq.disableAnimations), child: child!);
          },
          theme: ThemeData(
            fontFamily: 'Inter',
            brightness: Brightness.light,
            scaffoldBackgroundColor: const Color(0xFFF4F3F0),
            cardColor: Colors.white,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFFF6B00),
              brightness: Brightness.light,
              surface: const Color(0xFFF4F3F0),
            ),
            dialogTheme: _dialogTheme(dark: false),
            textButtonTheme: _textButtonTheme,
            pageTransitionsTheme: still ? _noTransitions : null,
          ),
          darkTheme: ThemeData(
            fontFamily: 'Inter',
            brightness: Brightness.dark,
            scaffoldBackgroundColor: const Color(0xFF111827),
            cardColor: const Color(0xFF1F2937),
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFFF6B00),
              brightness: Brightness.dark,
              surface: const Color(0xFF1F2937),
            ),
            dialogTheme: _dialogTheme(dark: true),
            textButtonTheme: _textButtonTheme,
            pageTransitionsTheme: still ? _noTransitions : null,
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

class _NoTransition extends PageTransitionsBuilder {
  const _NoTransition();

  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation,
          Animation<double> secondaryAnimation, Widget child) =>
      child;
}

class SessionInitializer extends StatefulWidget {
  const SessionInitializer({super.key});

  @override
  State<SessionInitializer> createState() => _SessionInitializerState();
}

/// Intro screen: plays the siren animation while the saved login is checked,
/// then fades into the right screen as the siren drives off the top.
class _SessionInitializerState extends State<SessionInitializer> {
  /// Loading progress shown by the rays: 0..1, 1 once the next screen is known.
  final _progress = ValueNotifier(0.0);
  Widget? _next;

  @override
  void initState() {
    super.initState();
    _checkSession();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Decode the layers up front so no ray pops in late on the first cycle
    precacheImage(const AssetImage('assets/logos/splash/siren.png'), context);
    for (var i = 1; i <= 10; i++) {
      precacheImage(AssetImage('assets/logos/splash/ray_$i.png'), context);
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  /// Replaces the intro with the chosen screen using a fade.
  void _go() {
    final screen = _next;
    if (screen == null || !mounted) return;
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        // Going to login, the siren and name glide into place (Hero), so take it slow
        transitionDuration: DisplaySettings.reducedMotion.value
            ? Duration.zero
            : Duration(milliseconds: screen is LoginScreen ? 1100 : 450),
        pageBuilder: (_, _, _) => screen,
        transitionsBuilder: (_, animation, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
          child: child,
        ),
      ),
    );
  }

  Future<void> _checkSession() async {
    var session = await SessionService.getSession();
    _progress.value = 0.4;
    // A saved session is only usable if the Firebase login can be restored too
    if (session != null && await FirebaseAuthRest.restore() == null) {
      await SessionService.clearSession();
      session = null;
    }
    _progress.value = 0.85;

    if (!mounted) return;

    if (session != null) {
      final userId = session['id'] as int;
      final role = session['role'] as String;
      final fullName = session['fullName'] as String;

      final home = homeForRole(role);
      if (home == RoleHome.superAdmin) {
        _next = SuperAdminShell(
          isSuperAdmin: true,
          userId: userId,
        );
      } else if (home == RoleHome.admin) {
        _next = AdminShell(
          userId: userId,
        );
      } else {
        _next = HomeScreen(
          citizenId: userId.toString(),
          userName: fullName,
        );
      }
    } else {
      // Check for a remembered device here, so the login form is ready on its
      // first frame and the siren can glide into its logo
      final trusted = await LoginScreen.findTrustedUser();
      _next = LoginScreen(trustedChecked: true, trustedUser: trusted);
    }
    _progress.value = 1;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false, // keyboard covers the screen instead of pushing it up
      backgroundColor: ThemeService.instance.pageBackground,
      body: Center(
        child: SplashSiren(
          progress: _progress,
          onDone: _go,
          glideOnExit: () => _next is LoginScreen && (_next as LoginScreen).trustedUser == null,
          caption: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Hero(
                tag: resqNameHeroTag,
                child: Material(
                  type: MaterialType.transparency,
                  child: Text(
                    'ResQ',
                    style: TextStyle(
                      fontFamily: 'Bangers',
                      fontSize: 56,
                      height: 1.0, // the font's tall line box left a big gap under the siren
                      letterSpacing: 2.5,
                      color: resqOrange,
                    ),
                  ),
                ),
              ),
              Text(
                'Emergency Response Portal',
                style: TextStyle(fontSize: 14, color: ThemeService.instance.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
