import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

/// A log handler that stores recent log records in memory.
class InMemoryLogHandler {
  final List<LogRecord> _records = [];
  final int maxEntries;

  /// Creates an in-memory log handler.
  ///
  /// [maxEntries] defines the maximum number of log records to store.
  /// When the limit is reached, the oldest entry is removed.
  InMemoryLogHandler({this.maxEntries = 1000});

  /// The list of stored log records.
  List<LogRecord> get records => List.unmodifiable(_records);

  /// Handles an incoming log record by adding it to the in-memory list.
  void handleRecord(LogRecord record) {
    if (_records.length >= maxEntries) {
      _records.removeAt(0); // Remove the oldest entry
    }
    _records.add(record);
    // Optionally notify listeners if this becomes a ChangeNotifier
  }

  /// Clears all stored log records.
  void clear() {
    _records.clear();
    // Optionally notify listeners
  }

  /// Formats a LogRecord into a simple string.
  static String formatRecord(LogRecord record) {
    final time =
        record.time.toIso8601String().substring(11, 23); // HH:mm:ss.mmm
    var message =
        '${record.level.name} $time ${record.loggerName}: ${record.message}';
    if (record.error != null) {
      message += '\n  Error: ${record.error}';
    }
    // Optionally include stack trace in debug mode or for severe errors
    if (kDebugMode && record.stackTrace != null ||
        (record.level >= Level.SEVERE && record.stackTrace != null)) {
      message += '\n  Stack: ${record.stackTrace}';
    }
    return message;
  }
}
