import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

class InMemoryLogHandler {
  final List<LogRecord> _records = [];
  final int maxEntries;

  InMemoryLogHandler({this.maxEntries = 1000});

  List<LogRecord> get records => List.unmodifiable(_records);

  void handleRecord(LogRecord record) {
    if (_records.length >= maxEntries) {
      _records.removeAt(0);
    }
    _records.add(record);
  }

  void clear() {
    _records.clear();
  }

  static String formatRecord(LogRecord record) {
    final time = record.time.toIso8601String().substring(11, 23);
    var message =
        '${record.level.name} $time ${record.loggerName}: ${record.message}';
    if (record.error != null) {
      message += '\n  Error: ${record.error}';
    }
    if (kDebugMode && record.stackTrace != null ||
        (record.level >= Level.SEVERE && record.stackTrace != null)) {
      message += '\n  Stack: ${record.stackTrace}';
    }
    return message;
  }
}
