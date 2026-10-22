import 'dart:io' show File, Platform;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

/// Makes the app icon's background match the theme: the light or dark page colour.
/// Windows swaps the window/taskbar icon at once. Android swaps the launcher
/// icon (an activity-alias in AndroidManifest.xml) only when the app goes to the
/// background, because some launchers close an app whose icon changes while open.
class AppIconService {
  static const _channel = MethodChannel('resq/app_icon');
  static bool? _dark;
  static bool _listening = false; // one listener for the app's lifetime

  static void match(bool dark) {
    if (_dark == dark) return;
    _dark = dark;
    if (Platform.isWindows) {
      final dir = File(Platform.resolvedExecutable).parent.path;
      final ico = '$dir\\data\\flutter_assets\\assets\\icons\\app_icon_${dark ? 'dark' : 'light'}.ico';
      windowManager.setIcon(ico).catchError((_) {});
    } else if (Platform.isAndroid && !_listening) {
      _listening = true;
      AppLifecycleListener(
        onPause: () => _channel.invokeMethod('setDark', _dark).catchError((_) => null),
      );
    }
  }
}
