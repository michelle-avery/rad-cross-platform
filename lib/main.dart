import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'dart:io';
import 'package:provider/provider.dart';
import 'providers/app_state_provider.dart';
import 'services/auth_service.dart';
import 'screens/app_shell.dart';
import 'package:flutter/foundation.dart';
import 'dart:developer' as developer;
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'logging/in_memory_log_handler.dart';
import 'logging/file_log_handler.dart';

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

  await _setupLogging();

  Logger('main').info("Build mode: ${kDebugMode ? 'debug' : 'release'}.");

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

Future<void> _setupLogging() async {
  const Map<String, Level> logLevelsMap = {
    'ALL': Level.ALL,
    'FINEST': Level.FINEST,
    'FINER': Level.FINER,
    'FINE': Level.FINE,
    'CONFIG': Level.CONFIG,
    'INFO': Level.INFO,
    'WARNING': Level.WARNING,
    'SEVERE': Level.SEVERE,
    'SHOUT': Level.SHOUT,
    'OFF': Level.OFF,
  };
  const String logLevelPrefKey = 'logLevel';
  Level configuredLevel = Level.INFO; // Default level

  try {
    final prefs = await SharedPreferences.getInstance();
    final String? savedLevelName = prefs.getString(logLevelPrefKey);

    if (savedLevelName != null) {
      configuredLevel =
          logLevelsMap[savedLevelName.toUpperCase()] ?? Level.INFO;
      if (logLevelsMap[savedLevelName.toUpperCase()] == null) {
        Logger('main').warning(
            'Invalid log level "$savedLevelName" in preferences, defaulting to INFO.');
      }
    } else {
      Logger('main').info('No log level preference found, defaulting to INFO.');
    }
  } catch (e, s) {
    Logger('main').severe(
        'Error reading log level preference, defaulting to INFO.', e, s);
    configuredLevel = Level.INFO;
  }

  Logger.root.level = configuredLevel;
  Logger('main')
      .info('Logger initialized with level: ${Logger.root.level.name}');

  if (Platform.isLinux) {
    try {
      final Directory appSupportDir = await getApplicationSupportDirectory();
      final String logFilePath =
          p.join(appSupportDir.path, 'logs', 'radcxp.log');
      fileLogHandler = FileLogHandler(logFilePath);
      await fileLogHandler!.initialize();
      Logger('main').info(
          "Linux platform detected. File logging initialized to: $logFilePath");

      void linuxLogListener(LogRecord record) {
        fileLogHandler?.handleRecord(record);
        developer.log(
          record.message,
          time: record.time,
          level: record.level.value,
          name: record.loggerName,
          error: record.error,
          stackTrace: record.stackTrace,
        );
      }

      Logger.root.onRecord.listen(linuxLogListener);

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
      Logger('main').severe(
          '!!! Failed to initialize Linux file logging. Using fallback console logging.',
          e,
          stackTrace);
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
    }
  } else if (Platform.isAndroid) {
    Logger.root.onRecord.listen((record) {
      print(
          '${record.level.name}: ${record.time}: ${record.loggerName}: ${record.message}');
      if (record.error != null) {
        print('  Error: ${record.error}');
      }
      if (record.stackTrace != null) {
        print('  Stack trace:\n${record.stackTrace}');
      }

      inMemoryLogHandler.handleRecord(record);
    });
    Logger('main').info(
        "Android platform detected. Using print() for console logging. In-memory handler active.");
  } else {
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
