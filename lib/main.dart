import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'dart:io';
import 'package:provider/provider.dart';
import 'app_state_provider.dart';
import 'auth_service.dart';
import 'screens/app_shell.dart';
import 'package:flutter/foundation.dart'; // Import for kDebugMode

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows)) {
    if (runWebViewTitleBarWidget(args)) {
      return;
    }
  }

  if (Platform.isAndroid) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  final isDebug = kDebugMode;
  print("Running in debug mode: $isDebug");

  final appStateProvider = AppStateProvider();
  final authService = AuthService();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: appStateProvider),
        ChangeNotifierProvider.value(value: authService),
      ],
      child: const RadApp(),
    ),
  );
}
