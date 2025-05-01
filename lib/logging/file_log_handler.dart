import 'dart:io';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p; // For path manipulation

/// A log handler that writes records to a file.
class FileLogHandler {
  final String filePath;
  IOSink? _sink;
  bool _isInitialized = false;

  /// Creates a file log handler.
  /// [filePath] is the full path to the log file.
  FileLogHandler(this.filePath);

  /// Initializes the handler by opening the log file.
  /// Creates the directory if it doesn't exist.
  Future<void> initialize() async {
    if (_isInitialized) return;
    try {
      final logFile = File(filePath);
      final logDir = Directory(p.dirname(filePath));

      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
        print('[FileLogHandler] Created log directory: ${logDir.path}');
      }

      // Open the file in append mode
      _sink = logFile.openWrite(mode: FileMode.append);
      _isInitialized = true;
      print('[FileLogHandler] Initialized. Logging to: $filePath');
      // Write a marker indicating a new session start
      _sink?.writeln('-' * 50);
      _sink
          ?.writeln('Log session started: ${DateTime.now().toIso8601String()}');
      _sink?.writeln('-' * 50);
    } catch (e) {
      print('[FileLogHandler] Error initializing file logger: $e');
      _isInitialized = false;
      _sink = null; // Ensure sink is null if init fails
    }
  }

  /// Handles an incoming log record by writing it to the file.
  void handleRecord(LogRecord record) {
    if (!_isInitialized || _sink == null) {
      print(
          '[FileLogHandler] Not initialized, cannot write record: ${record.message}');
      return;
    }

    try {
      _sink?.writeln(formatRecord(record));
    } catch (e) {
      print('[FileLogHandler] Error writing log record: $e');
      // Attempt to close and nullify sink on error? Maybe too aggressive.
    }
  }

  /// Closes the log file sink.
  Future<void> close() async {
    if (_isInitialized && _sink != null) {
      try {
        print('[FileLogHandler] Closing log file sink.');
        await _sink?.flush();
        await _sink?.close();
      } catch (e) {
        print('[FileLogHandler] Error closing log sink: $e');
      } finally {
        _sink = null;
        _isInitialized = false;
      }
    }
  }

  /// Formats a LogRecord into a simple string for file output.
  static String formatRecord(LogRecord record) {
    final time = record.time.toIso8601String(); // Full timestamp for file
    var message =
        '${record.level.name} $time [${record.loggerName}] ${record.message}';
    if (record.error != null) {
      message += '\n  Error: ${record.error}';
    }
    if (record.stackTrace != null) {
      // Indent stack trace for readability
      final stackTraceString = record.stackTrace
          .toString()
          .split('\n')
          .map((line) => '    $line')
          .join('\n');
      message += '\n  Stack Trace:\n$stackTraceString';
    }
    return message;
  }
}
