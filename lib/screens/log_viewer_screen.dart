import 'dart:io';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';

import '../main.dart';
import '../logging/in_memory_log_handler.dart';

class LogViewerScreen extends StatefulWidget {
  const LogViewerScreen({super.key});

  @override
  State<LogViewerScreen> createState() => _LogViewerScreenState();
}

class _LogViewerScreenState extends State<LogViewerScreen> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  void _clearLogs() {
    setState(() {
      inMemoryLogHandler.clear();
    });
  }

  Future<void> _shareLogs() async {
    final records = inMemoryLogHandler.records;
    if (records.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No logs to share.')),
      );
      return;
    }

    try {
      final logBuffer = StringBuffer();
      for (final record in records) {
        logBuffer.writeln(InMemoryLogHandler.formatRecord(record));
      }
      final logContent = logBuffer.toString();

      final tempDir = await getTemporaryDirectory();
      final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final fileName = 'rad_logs_$timestamp.log';
      final logFile = File('${tempDir.path}/$fileName');

      await logFile.writeAsString(logContent);

      final result = await Share.shareXFiles(
        [XFile(logFile.path)],
        text: 'RAD Application Logs',
      );

      if (result.status == ShareResultStatus.success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Logs shared successfully.')),
        );
      } else if (result.status == ShareResultStatus.dismissed) {
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to share logs: ${result.status}')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error preparing logs for sharing: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final records = inMemoryLogHandler.records;

    return Scaffold(
      appBar: AppBar(
        title: const Text('App Logs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_forever),
            tooltip: 'Clear Logs',
            onPressed: _clearLogs,
          ),
          IconButton(
            icon: const Icon(Icons.arrow_downward),
            tooltip: 'Scroll to Bottom',
            onPressed: _scrollToBottom,
          ),
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Share Logs',
            onPressed: _shareLogs,
          ),
        ],
      ),
      body: ListView.builder(
        controller: _scrollController,
        itemCount: records.length,
        itemBuilder: (context, index) {
          final record = records[index];
          final formattedRecord = InMemoryLogHandler.formatRecord(record);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
            child: SelectableText(
              formattedRecord,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.0,
                color: _getColorForLevel(record.level),
              ),
            ),
          );
        },
      ),
    );
  }

  Color _getColorForLevel(Level level) {
    if (level == Level.SEVERE || level == Level.SHOUT) {
      return Colors.red;
    } else if (level == Level.WARNING) {
      return Colors.orange;
    } else if (level == Level.INFO) {
      return Colors.blueGrey;
    } else if (level == Level.CONFIG) {
      return Colors.blue;
    } else {
      // FINE, FINER, FINEST
      return Colors.grey;
    }
  }
}
