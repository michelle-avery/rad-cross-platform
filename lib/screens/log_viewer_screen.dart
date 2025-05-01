import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import '../main.dart'; // To access the global inMemoryLogHandler
import '../logging/in_memory_log_handler.dart'; // For formatRecord

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
    // Optionally scroll to bottom when the screen is first built
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

  @override
  Widget build(BuildContext context) {
    // Use ListenableBuilder or similar if handler becomes a ChangeNotifier
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
            // Using SelectableText to allow copying log messages
            child: SelectableText(
              formattedRecord,
              style: TextStyle(
                fontFamily: 'monospace', // Use a monospace font for logs
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
