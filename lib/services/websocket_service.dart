import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:radcxp/services/auth_service.dart';
import 'package:logging/logging.dart'; // Import logging
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as status;

// Logger instance
final _log = Logger('WebSocketService');

class _PendingCommand {
  final Completer<Map<String, dynamic>> completer;
  final String commandType;

  _PendingCommand(this.completer, this.commandType);
}

class WebSocketService {
  static WebSocketService? _instance;
  final StreamController<Map<String, dynamic>> _messageController =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<String> _navigationTargetController =
      StreamController<String>.broadcast();
  bool _connected = false;
  bool _isConnecting = false;
  int _commandId = 1;
  final Map<int, _PendingCommand> _pendingCommands = {};
  String? _token;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  String? _wsUrl;
  String? _baseUrl;
  String? _deviceId;
  WebSocketChannel? _channel;
  final Duration _heartbeatInterval = const Duration(seconds: 30);
  final Duration _reconnectDelay = const Duration(seconds: 5);

  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;
  Stream<String> get navigationTargetStream =>
      _navigationTargetController.stream;
  bool get isConnected => _connected;

  static WebSocketService getInstance() {
    _instance ??= WebSocketService._internal();
    return _instance!;
  }

  WebSocketService._internal();

  Future<void> connect(
    String baseUrl,
    AuthService authService,
    String deviceId,
  ) async {
    if (_connected || _isConnecting) {
      _log.fine(
          'Already connected or connection in progress. Skipping connect call.');
      return;
    }
    if (_reconnectTimer != null && _reconnectTimer!.isActive) {
      _log.fine('Reconnection attempt already scheduled.');
      return;
    }

    _isConnecting = true;
    _connected = false;

    _reconnectTimer?.cancel();

    _baseUrl = baseUrl;
    _deviceId = deviceId;
    _wsUrl = baseUrl.replaceAll(RegExp(r'^http'), 'ws') + '/api/websocket';
    _log.info('Attempting to connect to $_wsUrl... (Device ID: $_deviceId)');

    try {
      _token = await authService.getValidAccessToken();

      if (_token == null) {
        _log.warning(
            'Connection failed - Unable to get a valid access token (refresh might have failed or user needs re-login).');
        _handleDisconnect(scheduleReconnect: false);
        return;
      }
      _log.fine(
          'Using valid access token: ${_token!.substring(0, 10)}...'); // Fine level for potentially sensitive info

      // TODO: Implement proper certificate validation for production.
      // Consider making this configurable or using platform-specific trust mechanisms.
      // Removed badCertificateCallback to enforce valid SSL certificates.
      final httpClient = HttpClient();
      // final socket = await WebSocket.connect(_wsUrl!); // Use default client
      final socket = await WebSocket.connect(_wsUrl!,
          customClient: httpClient); // Or pass the default client explicitly
      _channel = IOWebSocketChannel(socket);

      _log.info('Connection established, waiting for messages...');

      _channel!.stream.listen(
        (message) {
          try {
            final decodedMessage = jsonDecode(message);
            if (decodedMessage is Map<String, dynamic>) {
              _handleMessage(decodedMessage);
            } else {
              _log.warning('Received non-JSON message: $message');
            }
          } catch (e, stackTrace) {
            _log.severe('Error decoding message: $message', e, stackTrace);
          }
        },
        onError: (error, stackTrace) {
          _log.severe('WebSocket error.', error, stackTrace);
          _handleDisconnect();
        },
        onDone: () {
          _log.info('WebSocket connection closed by server.');
          _handleDisconnect();
        },
        cancelOnError: true,
      );
    } catch (e, stackTrace) {
      _log.severe('Connection failed.', e, stackTrace);
      _isConnecting = false;
      _handleDisconnect();
    }
  }

  void disconnect() {
    _log.info('Disconnecting...');
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _connected = false;
    _isConnecting = false;
    _pendingCommands.forEach((id, pendingCmd) {
      if (!pendingCmd.completer.isCompleted) {
        pendingCmd.completer.completeError(
            Exception('WebSocket disconnected before command $id completed.'));
      }
    });
    _pendingCommands.clear();
    _channel?.sink.close(status.normalClosure);
    _channel = null;
    _wsUrl = null;
  }

  void dispose() {
    _log.info('Disposing...');
    disconnect(); // disconnect already logs
    _messageController.close();
    _navigationTargetController.close();
    _instance = null;
  }

  void _handleMessage(Map<String, dynamic> message) {
    final messageType = message['type'] as String?;
    _log.fine(
        'Received message type: $messageType'); // Fine for frequent messages

    switch (messageType) {
      case 'auth_required':
        _authenticate();
        break;
      case 'auth_ok':
        _connected = true;
        _isConnecting = false;
        _reconnectTimer?.cancel();
        _log.info('Authenticated successfully.');
        _registerAndInitialize();
        break;
      case 'auth_invalid':
        _log.warning('Authentication failed: ${message['message']}');
        _isConnecting = false;
        _handleDisconnect(scheduleReconnect: false);
        break;
      case 'result':
        final id = message['id'] as int?;
        if (id != null && _pendingCommands.containsKey(id)) {
          final pendingCmd = _pendingCommands.remove(id)!;
          final completer = pendingCmd.completer;
          final originalCommandType = pendingCmd.commandType;

          if (message['success'] == true) {
            final resultData = message['result'];

            if (resultData is Map<String, dynamic>) {
              completer.complete(resultData);
            } else {
              _log.warning(
                  'Received successful non-map result ($resultData) for command type $originalCommandType. Completing with empty map.');
              completer.complete({});
            }
          } else {
            final errorMessage =
                message['error']?['message']?.toString() ?? 'Unknown error';
            final errorCode = message['error']?['code']?.toString();
            completer.completeError(
              WebSocketException(
                errorMessage,
                code: errorCode,
              ),
            );
          }
        } else {
          _log.warning('Received result for unknown id: $id');
        }
        break;
      case 'event':
        final eventData = message['event'] as Map<String, dynamic>?;
        final command = eventData?['command'] as String?;

        if (command == 'remote_assist_display/navigate_url') {
          final url = eventData?['url'] as String?;
          if (url != null && url.isNotEmpty) {
            _log.info('Received navigate_url command: $url');
            _navigationTargetController.add(url);
          } else {
            _log.warning(
                'Received navigate_url command with missing/empty url.');
          }
        } else if (command == 'remote_assist_display/navigate') {
          final path = eventData?['path'] as String?;
          if (path != null && path.isNotEmpty) {
            _log.info('Received navigate command: $path');
            _navigationTargetController.add(path);
          } else {
            _log.warning('Received navigate command with missing/empty path.');
          }
        } else {
          // Log other events if needed, or just pass them through
          _log.fine('Received unhandled event command: $command');
          _messageController.add(message);
        }
        break;
      case 'pong':
        final id = message['id'] as int?;
        _log.finest(
            'Received pong for id: $id'); // Finest for very frequent/low-level
        break;
      default:
        _log.warning('Received unhandled message type: $messageType');
        _messageController.add(message); // Still forward if needed
        break;
    }
  }

  void _authenticate() {
    if (_token != null) {
      _log.info('Sending auth message...');
      final authMessage = jsonEncode({
        'type': 'auth',
        'access_token': _token, // Token itself is not logged
      });
      _channel?.sink.add(authMessage);
    } else {
      _log.severe('Cannot authenticate - token is null. Disconnecting.');
      _handleDisconnect(scheduleReconnect: false);
    }
  }

  void _handleDisconnect({bool scheduleReconnect = true}) {
    if (!_connected && _reconnectTimer != null && _reconnectTimer!.isActive) {
      // Already handling disconnect or reconnect scheduled, avoid redundant logging/actions
      return;
    }
    _log.info('Handling disconnect. Schedule reconnect: $scheduleReconnect');

    _connected = false;
    _isConnecting = false;
    _pingTimer?.cancel();
    _reconnectTimer?.cancel();

    _channel?.sink.close(status.normalClosure).catchError((error, stackTrace) {
      _log.warning('Error closing channel sink.', error, stackTrace);
    });
    _channel = null;

    _pendingCommands.forEach((id, pendingCmd) {
      if (!pendingCmd.completer.isCompleted) {
        pendingCmd.completer.completeError(
            Exception('WebSocket disconnected before command $id completed.'));
      }
    });
    _pendingCommands.clear();
  }

  void _startHeartbeat() {
    _pingTimer?.cancel();
    _log.info(
        'Starting heartbeat timer (${_heartbeatInterval.inSeconds}s interval).');
    _pingTimer = Timer.periodic(_heartbeatInterval, (_) => _sendPing());
    _sendPing(); // _sendPing logs its own messages
  }

  void _sendPing() {
    if (_connected && _channel != null) {
      final pingId = _commandId++;
      _log.finest('Sending ping (id: $pingId)...'); // Finest for frequent pings
      try {
        final pingMessage = jsonEncode({
          'id': pingId,
          'type': 'ping',
        });
        _channel!.sink.add(pingMessage);
      } catch (e, stackTrace) {
        _log.severe('Error sending ping.', e, stackTrace);
        _handleDisconnect(); // Disconnect on error
      }
    } else {
      _log.warning('Cannot send ping - not connected.');
      _pingTimer?.cancel(); // Stop trying if not connected
    }
  }

  Future<void> _registerAndInitialize() async {
    if (_deviceId == null) {
      _log.warning('Cannot register, deviceId is null.');
      return;
    }

    _log.info('Starting registration process...');
    try {
      await registerDisplay(
        deviceId: _deviceId!,
      ); // registerDisplay logs its own messages
      _log.info('Registration command sent successfully.');

      try {
        _log.info('Fetching display settings...');
        final settingsResult = await getDisplaySettings(deviceId: _deviceId!);
        // getDisplaySettings logs its own messages
        final settings = settingsResult['settings'] as Map<String, dynamic>?;
        final defaultDashboard = settings?['default_dashboard'] as String?;

        if (defaultDashboard != null && defaultDashboard.isNotEmpty) {
          _log.info('Found default dashboard: $defaultDashboard');
          _navigationTargetController.add(defaultDashboard);
        } else {
          _log.info('No default dashboard found in settings.');
        }
      } catch (e, stackTrace) {
        _log.severe('Failed to get display settings.', e, stackTrace);
      }

      await _subscribeToEventsSafe(); // subscribeToEventsSafe logs its own messages
      _log.info('Initialization complete, starting heartbeat.');
      _startHeartbeat(); // _startHeartbeat logs its own messages
    } catch (e, stackTrace) {
      _log.severe(
          'Error during _registerAndInitialize (registration or settings).',
          e,
          stackTrace);
    }
  }

  Future<void> _subscribeToEventsSafe() async {
    if (_deviceId != null) {
      try {
        await subscribeToEvents(deviceId: _deviceId!);
        // subscribeToEvents logs its own success/failure
      } catch (e, stackTrace) {
        // Log the error here if subscribeToEvents rethrows
        _log.severe(
            'Subscription failed in _subscribeToEventsSafe.', e, stackTrace);
      }
    } else {
      _log.warning(
          'Cannot subscribe, deviceId is null in _subscribeToEventsSafe.');
    }
  }

  Future<String> _getDeviceHostname() async {
    // TODO: Implement actual hostname retrieval using device_info_plus or similar
    return 'Unknown Device';
  }

  Future<Map<String, dynamic>> sendCommand(
    Map<String, dynamic> command, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (!_connected || _channel == null) {
      throw WebSocketException('Not connected to WebSocket.');
    }

    final commandId = _commandId++;
    final commandToSend = Map<String, dynamic>.from(command);
    commandToSend['id'] = commandId;
    final commandType = commandToSend['type'] as String? ?? 'unknown';

    final pendingCommand =
        _PendingCommand(Completer<Map<String, dynamic>>(), commandType);
    _pendingCommands[commandId] = pendingCommand;

    _log.fine(
        'Sending command (id: $commandId): ${commandToSend['type']}'); // Fine for commands

    try {
      final message = jsonEncode(commandToSend);
      _channel!.sink.add(message);

      final result =
          await pendingCommand.completer.future.timeout(timeout, onTimeout: () {
        _pendingCommands.remove(commandId);
        throw TimeoutException(
            'Command $commandId (${commandToSend['type']}) timed out after ${timeout.inSeconds} seconds.');
      });
      return result;
    } catch (e, stackTrace) {
      _pendingCommands.remove(commandId); // Ensure cleanup on error
      if (e is TimeoutException) {
        // TimeoutException is already logged by the timeout callback, avoid duplicate severe log
        _log.warning(
            'Command $commandId (${commandToSend['type']}) timed out.');
      } else {
        _log.severe('Error sending command $commandId.', e, stackTrace);
      }
      rethrow; // Rethrow the original exception
    }
  }

  Future<Map<String, dynamic>> registerDisplay({
    required String deviceId,
  }) async {
    final hostname = await _getDeviceHostname();

    final Map<String, dynamic> command = {
      'type': 'remote_assist_display/register',
      'hostname': hostname,
      'display_id': deviceId,
    };

    _log.info(
        'Registering display (sending remote_assist_display/register)...');
    try {
      final result = await sendCommand(command);
      _log.fine(
          'Display registration successful: $result'); // Fine for result details
      return result;
    } catch (e, stackTrace) {
      _log.severe('Display registration failed.', e, stackTrace);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> subscribeToEvents({
    required String deviceId,
  }) async {
    final command = {
      'type': 'remote_assist_display/connect',
      'display_id': deviceId,
    };

    _log.info(
        'Subscribing to events (sending remote_assist_display/connect) for device $deviceId...');
    try {
      final result = await sendCommand(command);
      _log.fine(
          'Event subscription successful: $result'); // Fine for result details
      return result;
    } catch (e, stackTrace) {
      // sendCommand already logs the error, but we log specifically for subscription failure context
      _log.severe('Event subscription failed.', e, stackTrace);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> getDisplaySettings({
    required String deviceId,
  }) async {
    final command = {
      'type': 'remote_assist_display/settings',
      'display_id': deviceId,
    };
    _log.info(
        'Getting display settings (sending remote_assist_display/settings)...');
    try {
      final result = await sendCommand(command);
      _log.fine('Get settings successful: $result'); // Fine for result details
      if (result.containsKey('settings') &&
          result['settings'] is Map<String, dynamic>) {
        return result;
      } else {
        throw WebSocketException(
            'Settings data missing or not a map in response.',
            code: 'invalid_response');
      }
    } catch (e, stackTrace) {
      // sendCommand already logs the error, but we log specifically for settings failure context
      _log.severe('Get settings failed.', e, stackTrace);
      rethrow;
    }
  }

  Future<void> updateCurrentUrl(String url) async {
    if (!_connected || _channel == null) {
      _log.warning('Cannot update URL - not connected.');
      return;
    }
    if (_deviceId == null) {
      _log.warning('Cannot update URL - deviceId is null.');
      return;
    }

    final Map<String, dynamic> command = {
      'type': 'remote_assist_display/update',
      'display_id': _deviceId,
      'data': {
        'display': {
          'current_url': url,
        },
      },
    };

    _log.info('Sending URL update (remote_assist_display/update)... URL: $url');
    try {
      // Use sendCommand without await if we don't need the result immediately
      // and want to avoid blocking if the command takes time.
      // However, awaiting helps ensure the command was at least attempted to be sent.
      await sendCommand(command, timeout: const Duration(seconds: 5));
      _log.fine(
          'URL update command sent successfully.'); // Fine for success confirmation
    } catch (e, stackTrace) {
      // sendCommand logs the error, but we add context
      _log.severe('Failed to send URL update command.', e, stackTrace);
      // Decide if rethrowing is necessary. Here, maybe not, as it's an update.
    }
  }
}

class WebSocketException implements Exception {
  final String message;
  final String? code;

  WebSocketException(this.message, {this.code});

  @override
  String toString() {
    return 'WebSocketException: ${code ?? 'UnknownCode'} - $message';
  }
}
