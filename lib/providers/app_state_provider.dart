import 'dart:io';

import 'package:flutter/material.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../services/auth_service.dart';
import '../services/websocket_service.dart';

class AppStateProvider extends ChangeNotifier {
  bool _isConfigured = false;
  String? _homeAssistantUrl;
  String? _deviceId;
  String? _hostName = "Unknown";

  final AuthService _authService;

  static const String _deviceIdKey = 'unique_device_id';
  static const String _haUrlKey = 'home_assistant_url';

  bool get isConfigured => _isConfigured;
  String? get homeAssistantUrl => _homeAssistantUrl;
  String? get deviceId => _deviceId;

  AppStateProvider(this._authService) {
    debugPrint('[AppStateProvider] Constructor called.');
    _initialize();
  }

  Future<void> _initialize() async {
    await _loadSavedState();
    await _loadOrGenerateDeviceId();
    _authService.addListener(_handleAuthStateChanged);
    _handleAuthStateChanged();
  }

  @override
  void dispose() {
    debugPrint('[AppStateProvider] Disposing...');
    _authService.removeListener(_handleAuthStateChanged);
    WebSocketService.getInstance().dispose();
    super.dispose();
  }

  Future<void> _loadSavedState() async {
    final prefs = await SharedPreferences.getInstance();
    _homeAssistantUrl = prefs.getString(_haUrlKey);
    debugPrint('[AppStateProvider] Loaded $_haUrlKey: $_homeAssistantUrl');
    _isConfigured = _homeAssistantUrl != null && _homeAssistantUrl!.isNotEmpty;
    debugPrint('[AppStateProvider] isConfigured: $_isConfigured');
  }

  Future<void> _loadOrGenerateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    _deviceId = prefs.getString(_deviceIdKey);

    if (_deviceId == null) {
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        _hostName = androidInfo.host;
        debugPrint('[AppStateProvider] Hostname: $_hostName');
      } else if (Platform.isLinux) {
        _hostName = Platform.localHostname;
        debugPrint('[AppStateProvider] Hostname: $_hostName');
      } else {
        _hostName = "Unknown";
      }
      final randomID = const Uuid().v4().substring(0, 12);
      _deviceId = 'rad-$randomID-$_hostName';
      await prefs.setString(_deviceIdKey, _deviceId!);
      debugPrint(
          '[AppStateProvider] Generated and saved new device ID: $_deviceId');
    } else {
      debugPrint('[AppStateProvider] Retrieved existing device ID: $_deviceId');
    }
    notifyListeners();
  }

  /// Allows overriding the device ID (e.g., for migration).
  Future<void> setDeviceId(String newDeviceId) async {
    if (newDeviceId.isNotEmpty && _deviceId != newDeviceId) {
      final prefs = await SharedPreferences.getInstance();
      _deviceId = newDeviceId;
      await prefs.setString(_deviceIdKey, _deviceId!);
      debugPrint('[AppStateProvider] Set device ID override: $_deviceId');
      notifyListeners();
    }
  }

  Future<void> setHomeAssistantUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    _homeAssistantUrl = url;
    _isConfigured = true;
    await prefs.setString(_haUrlKey, url);
    debugPrint('[AppStateProvider] Saved $_haUrlKey: $_homeAssistantUrl');
    notifyListeners();
    _handleAuthStateChanged();
  }

  Future<void> resetConfiguration() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_haUrlKey);
    debugPrint('[AppStateProvider] Removed $_haUrlKey');
    _homeAssistantUrl = null;
    _isConfigured = false;
    notifyListeners();
    _handleAuthStateChanged();
  }

  void _handleAuthStateChanged() {
    debugPrint(
        '[AppStateProvider] Handling Auth State Change. AuthState: ${_authService.state}, URL: $_homeAssistantUrl, DeviceID: $_deviceId'); // Added DeviceID log
    final wsService = WebSocketService.getInstance();

    if (_authService.state == AuthState.authenticated &&
        _homeAssistantUrl != null &&
        _homeAssistantUrl!.isNotEmpty &&
        _deviceId != null) {
      if (!wsService.isConnected) {
        debugPrint(
            '[AppStateProvider] Authenticated, URL set, DeviceID ready. Connecting WebSocket...');
        Future.microtask(() =>
            wsService.connect(_homeAssistantUrl!, _authService, _deviceId!));
      } else {
        debugPrint('[AppStateProvider] WebSocket already connected.');
      }
    } else {
      if (wsService.isConnected) {
        debugPrint(
            '[AppStateProvider] Not authenticated, URL missing, or DeviceID missing. Disconnecting WebSocket...');
        Future.microtask(() => wsService.disconnect());
      } else {
        debugPrint('[AppStateProvider] WebSocket already disconnected.');
      }
    }
  }
}
