import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'dart:io';
import 'package:provider/provider.dart';
import 'providers/app_state_provider.dart';
import 'services/auth_service.dart';
import 'screens/app_shell.dart';
import 'package:flutter/foundation.dart';
import 'dart:io'; // For Platform checks
import 'dart:developer' as developer; // For Android console logging
import 'package:logging/logging.dart'; // Logging package
import 'package:path_provider/path_provider.dart'; // For directory path
import 'package:path/path.dart' as p; // For path joining
import 'logging/in_memory_log_handler.dart'; // Import the handler
import 'logging/file_log_handler.dart'; // Import the file handler

// Global instance for simplicity, might be better managed via Provider later
final InMemoryLogHandler inMemoryLogHandler = InMemoryLogHandler();
FileLogHandler? fileLogHandler; // Global instance for file handler (nullable)

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
  // Setup logging first, so we can log the mode
  await _setupLogging(isDebug);

  // Log the debug status using the new logger
  Logger('main').info("Running in ${isDebug ? 'debug' : 'release'} mode.");

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthService()),
        ChangeNotifierProxyProvider<AuthService, AppStateProvider>(
          create: (context) => AppStateProvider(
            Provider.of<AuthService>(context, listen: false),
          ),
          // Return the existing instance if available, otherwise create it (via create).
          // AppStateProvider listens to authService internally.
          update: (context, authService, previousAppState) =>
              previousAppState ?? AppStateProvider(authService),
        ),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RAD Cross-Platform',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: const AppShell(),
    );
  }
}

// Logging setup function
Future<void> _setupLogging(bool isDebug) async {
  // Set the root level
  Logger.root.level = isDebug
      ? Level.ALL
      : Level.INFO; // Log everything in debug, INFO and above in release

  // Platform-specific handlers
  if (Platform.isLinux) {
    try {
      final Directory appSupportDir = await getApplicationSupportDirectory();
      // Consider adding rotation logic later (e.g., based on date or size)
      final String logFilePath =
          p.join(appSupportDir.path, 'logs', 'radcxp.log');
      fileLogHandler = FileLogHandler(logFilePath);
      await fileLogHandler!.initialize();

      Logger.root.onRecord.listen((record) {
        fileLogHandler?.handleRecord(record);
        // Optionally, also log to console in debug mode for Linux using developer.log
        // This keeps the format consistent with Android's debug console output
        if (isDebug) {
          developer.log(
            record.message,
            time: record.time,
            level: record.level.value,
            name: record.loggerName,
            error: record.error,
            stackTrace: record.stackTrace,
          );
        }
      });
      Logger('main').info(
          "Linux platform detected. File logging initialized to: $logFilePath");

      // Add hook to close file sink on exit (best effort)
      // Note: This might not always run, e.g., on force kill.
      // Consider using WidgetsBindingObserver.didChangeAppLifecycleState for more robustness if needed.
      ProcessSignal.sigint.watch().listen((signal) async {
        Logger('main').info('Received SIGINT, closing log file...');
        await fileLogHandler?.close();
        exit(0); // Exit after cleanup
      });
      ProcessSignal.sigterm.watch().listen((signal) async {
        Logger('main').info('Received SIGTERM, closing log file...');
        await fileLogHandler?.close();
        exit(0); // Exit after cleanup
      });
    } catch (e, stackTrace) {
      // Use the logger itself to report the failure
      Logger('main').severe(
          '!!! Failed to initialize Linux file logging.', e, stackTrace);
      // Fallback to console logging if file init fails
      Logger.root.onRecord.listen((record) {
        developer.log(
          // Use developer.log for fallback console too
          record.message,
          time: record.time,
          level: record.level.value,
          name: record.loggerName,
          error: record.error,
          stackTrace: record.stackTrace,
        );
      });
      Logger('main').warning(
          "Linux file logging failed. Using fallback console logging."); // Warning level seems more appropriate here
    }
  } else if (Platform.isAndroid) {
    // Console handler (prints to adb logcat)
    Logger.root.onRecord.listen((record) {
      developer.log(
        record.message,
        time: record.time,
        level: record.level.value,
        name: record.loggerName,
        error: record.error,
        stackTrace: record.stackTrace,
      );
      // Add record to the in-memory handler
      inMemoryLogHandler.handleRecord(record);
    });
    Logger('main').info(
        "Android platform detected. Console logging active. In-memory placeholder active.");
  } else {
    // Default/Fallback handler (e.g., for macOS/Windows development) - Use developer.log
    Logger.root.onRecord.listen((record) {
      developer.log(
        record.message,
        time: record.time,
        level: record.level.value,
        name: record.loggerName,
        error: record.error,
        stackTrace: record.stackTrace,
      );
    });
    Logger('main')
        .info("Other platform detected. Basic console logging active.");
  }
}
