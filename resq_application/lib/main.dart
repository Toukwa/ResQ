import 'package:flutter/material.dart';

import 'login.dart';
import 'citizen/home_screen.dart';
import 'superadmin/super_admin_shell.dart';
import 'admin/admin_shell.dart';
import 'services/session_service.dart';
import 'services/theme_service.dart';

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

  runApp(const MyApp());
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
          title: 'ResQ App',
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

class _SessionInitializerState extends State<SessionInitializer> {
  @override
  void initState() {
    super.initState();
    _checkSession();
  }

  Future<void> _checkSession() async {
    final session = await SessionService.getSession();

    if (!mounted) return;

    if (session != null) {
      final userId = session['id'] as int;
      final role = session['role'] as String;
      final fullName = session['fullName'] as String;

      if (role == 'Superadmin') {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => SuperAdminShell(
              isSuperAdmin: true,
              userId: userId,
            ),
          ),
        );
      } else if (role == 'Admin') {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => AdminShell(
              userId: userId,
            ),
          ),
        );
      } else {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => HomeScreen(
              citizenId: userId.toString(),
              userName: fullName,
            ),
          ),
        );
      }
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const LoginScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFFF8FAFC),
      body: Center(
        child: CircularProgressIndicator(
          color: Color(0xFFFF6B00),
        ),
      ),
    );
  }
}
