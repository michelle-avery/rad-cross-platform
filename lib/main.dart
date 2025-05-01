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
import 'dart:convert';

final InMemoryLogHandler inMemoryLogHandler = InMemoryLogHandler();
FileLogHandler? fileLogHandler;

class MyHttpOverrides extends HttpOverrides {
  final List<Uint8List> trustedCertBytes;

  MyHttpOverrides(this.trustedCertBytes);

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    SecurityContext effectiveContext =
        context ?? SecurityContext.defaultContext;

    if (Platform.isAndroid && trustedCertBytes.isNotEmpty) {
      Logger('MyHttpOverrides')
          .info('Applying custom SecurityContext for Android HttpClient.');
      effectiveContext = SecurityContext(withTrustedRoots: true);
      try {
        for (final certBytes in trustedCertBytes) {
          effectiveContext.setTrustedCertificatesBytes(certBytes);
        }
        Logger('MyHttpOverrides').fine(
            'Successfully added ${trustedCertBytes.length} custom CAs to SecurityContext.');
      } catch (e, s) {
        Logger('MyHttpOverrides').severe(
            'Error setting trusted certificates in SecurityContext.', e, s);
        effectiveContext = context ?? SecurityContext.defaultContext;
      }
    } else if (Platform.isAndroid) {
      Logger('MyHttpOverrides').warning(
          'Android platform detected, but no custom certificate bytes provided to HttpOverrides.');
    }

    final client = super.createHttpClient(effectiveContext);

    client.badCertificateCallback =
        (X509Certificate cert, String host, int port) {
      Logger('MyHttpOverrides').severe(
          'badCertificateCallback triggered! Cert: ${cert.subject}, Host: $host:$port. This indicates a trust issue despite custom CAs/NSC.');
      return false;
    };

    return client;
  }
}

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  List<Uint8List> customCertBytes = [];
  if (Platform.isAndroid) {
    try {
      Logger('main').info('Loading custom CA certificates for Android...');
      final ByteData isrgData =
          await rootBundle.load('assets/certs/isrgrootx1.pem');
      customCertBytes.add(isrgData.buffer.asUint8List());
      Logger('main').fine('Loaded isrgrootx1.pem');

      final ByteData r10Data = await rootBundle.load('assets/certs/r10.pem');
      customCertBytes.add(r10Data.buffer.asUint8List());
      Logger('main').fine('Loaded r10.pem');

      Logger('main').info(
          'Successfully loaded ${customCertBytes.length} custom CA certificates.');
    } catch (e, s) {
      Logger('main')
          .severe('Failed to load custom CA certificates from assets.', e, s);
    }
  }

  HttpOverrides.global = MyHttpOverrides(customCertBytes);
  Logger('main').info(
      'Applied custom HttpOverrides${customCertBytes.isNotEmpty ? ' with custom CAs' : ''}.');

  if (!kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows)) {
    if (runWebViewTitleBarWidget(args)) {
      return;
    }
  }

  if (Platform.isAndroid) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  final isDebug = kDebugMode;
  await _setupLogging(isDebug);

  Logger('main').info("Running in ${isDebug ? 'debug' : 'release'} mode.");

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthService()),
        ChangeNotifierProxyProvider<AuthService, AppStateProvider>(
          create: (context) => AppStateProvider(
            Provider.of<AuthService>(context, listen: false),
          ),
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

Future<void> _setupLogging(bool isDebug) async {
  Logger.root.level = isDebug ? Level.ALL : Level.INFO;
  if (Platform.isLinux) {
    try {
      final Directory appSupportDir = await getApplicationSupportDirectory();
      final String logFilePath =
          p.join(appSupportDir.path, 'logs', 'radcxp.log');
      fileLogHandler = FileLogHandler(logFilePath);
      await fileLogHandler!.initialize();

      Logger.root.onRecord.listen((record) {
        fileLogHandler?.handleRecord(record);
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

      ProcessSignal.sigint.watch().listen((signal) async {
        Logger('main').info('Received SIGINT, closing log file...');
        await fileLogHandler?.close();
        exit(0);
      });
      ProcessSignal.sigterm.watch().listen((signal) async {
        Logger('main').info('Received SIGTERM, closing log file...');
        await fileLogHandler?.close();
        exit(0);
      });
    } catch (e, stackTrace) {
      // Use the logger itself to report the failure
      Logger('main').severe(
          '!!! Failed to initialize Linux file logging.', e, stackTrace);
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
      Logger('main').warning(
          "Linux file logging failed. Using fallback console logging.");
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
