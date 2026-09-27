import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io' show Platform;

class AppConfig {
  // Use 127.0.0.1:3000 with ADB reverse port forwarding over USB (adb reverse tcp:3000 tcp:3000),
  // or computer LAN IP (192.168.1.9) when purely over Wi-Fi.
  static String get apiBaseUrl {
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      return 'http://127.0.0.1:3000/api';
    }
    // Use localhost for desktop/web
    return 'http://localhost:3000/api';
  }

  // Get the base URL for serving static files (images, etc.)
  static String get baseUrl {
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      return 'http://127.0.0.1:3000';
    }
    return 'http://localhost:3000';
  }
}
