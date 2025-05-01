import 'dart:io';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

class FileLogHandler {
  final String filePath;
  IOSink? _sink;
  bool _isInitialized = false;

  FileLogHandler(this.filePath);

  Future<void> initialize() async {
    if (_isInitialized) return;
    try {
      final logFile = File(filePath);
      final logDir = Directory(p.dirname(filePath));

      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
        print('[FileLogHandler] Created log directory: ${logDir.path}');
      }

      _sink = logFile.openWrite(mode: FileMode.append);
      _isInitialized = true;
      print('[FileLogHandler] Initialized. Logging to: $filePath');
      _sink?.writeln('-' * 50);
      _sink
          ?.writeln('Log session started: ${DateTime.now().toIso8601String()}');
      _sink?.writeln('-' * 50);
    } catch (e) {
      print('[FileLogHandler] Error initializing file logger: $e');
      _isInitialized = false;
      _sink = null;
    }
  }

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
    }
  }

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

  static String formatRecord(LogRecord record) {
    final time = record.time.toIso8601String();
    var message =
        '${record.level.name} $time [${record.loggerName}] ${record.message}';
    if (record.error != null) {
      message += '\n  Error: ${record.error}';
    }
    if (record.stackTrace != null) {
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
