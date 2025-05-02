import 'dart:io';

import 'package:flutter/material.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:logging/logging.dart';
import '../services/auth_service.dart';
import '../services/websocket_service.dart';

final _log = Logger('AppStateProvider');

class AppStateProvider extends ChangeNotifier {
  bool _isConfigured = false;
  String? _homeAssistantUrl;
  String? _deviceId;
  String? _hostName = "Unknown";
  bool? _hideHeader;
  bool? _hideSidebar;

  final AuthService _authService;

  static const String _deviceIdKey = 'unique_device_id';
  static const String _haUrlKey = 'home_assistant_url';
  static const String _hideHeaderKey = 'pref_hide_header';
  static const String _hideSidebarKey = 'pref_hide_sidebar';

  bool get isConfigured => _isConfigured;
  String? get homeAssistantUrl => _homeAssistantUrl;
  String? get deviceId => _deviceId;
  String? get hostName => _hostName;
  bool get hideHeader => _hideHeader ?? false;
  bool get hideSidebar => _hideSidebar ?? false;

  AppStateProvider(this._authService) {
    _log.fine('Constructor called.');
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
    _log.fine('Disposing...');
    _authService.removeListener(_handleAuthStateChanged);
    WebSocketService.getInstance().dispose();
    super.dispose();
  }

  Future<void> _loadSavedState() async {
    final prefs = await SharedPreferences.getInstance();
    _homeAssistantUrl = prefs.getString(_haUrlKey);
    _homeAssistantUrl = prefs.getString(_haUrlKey);
    _hideHeader = prefs.getBool(_hideHeaderKey);
    _hideSidebar = prefs.getBool(_hideSidebarKey);
    _log.info(
        'Loaded $_haUrlKey: $_homeAssistantUrl, $_hideHeaderKey: $_hideHeader, $_hideSidebarKey: $_hideSidebar');
    _isConfigured = _homeAssistantUrl != null && _homeAssistantUrl!.isNotEmpty;
    _log.info('isConfigured: $_isConfigured');
  }

  Future<void> _loadOrGenerateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    _deviceId = prefs.getString(_deviceIdKey);

    if (_deviceId == null) {
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        _hostName = androidInfo.host;
        _log.info('Hostname: $_hostName');
      } else if (Platform.isLinux) {
        _hostName = Platform.localHostname;
        _log.info('Hostname: $_hostName');
      } else {
        _hostName = "Unknown";
      }
      final randomID = const Uuid().v4().substring(0, 12);
      _deviceId = 'rad-$randomID-$_hostName';
      await prefs.setString(_deviceIdKey, _deviceId!);
      _log.info('Generated and saved new device ID: $_deviceId');
    } else {
      _log.info('Retrieved existing device ID: $_deviceId');
    }
    notifyListeners();
  }

  /// Allows overriding the device ID (e.g., for migration).
  Future<void> setDeviceId(String newDeviceId) async {
    if (newDeviceId.isNotEmpty && _deviceId != newDeviceId) {
      final prefs = await SharedPreferences.getInstance();
      _deviceId = newDeviceId;
      await prefs.setString(_deviceIdKey, _deviceId!);
      _log.info('Set device ID override: $_deviceId');
      notifyListeners();
    }
  }

  Future<void> setHomeAssistantUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    _homeAssistantUrl = url;
    _isConfigured = true;
    await prefs.setString(_haUrlKey, url);
    _log.info('Saved $_haUrlKey: $_homeAssistantUrl');
    notifyListeners();
    _handleAuthStateChanged();
  }

  Future<void> updateDisplaySettings(
      {bool? hideHeader, bool? hideSidebar}) async {
    final prefs = await SharedPreferences.getInstance();
    bool changed = false;

    if (hideHeader != null && _hideHeader != hideHeader) {
      _hideHeader = hideHeader;
      await prefs.setBool(_hideHeaderKey, _hideHeader!);
      _log.info('Updated $_hideHeaderKey: $_hideHeader');
      changed = true;
    }
    if (hideSidebar != null && _hideSidebar != hideSidebar) {
      _hideSidebar = hideSidebar;
      await prefs.setBool(_hideSidebarKey, _hideSidebar!);
      _log.info('Updated $_hideSidebarKey: $_hideSidebar');
      changed = true;
    }

    if (changed) {
      notifyListeners();
    }
  }

  Future<void> resetConfiguration() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_haUrlKey);
    _log.info('Removed $_haUrlKey');
    _homeAssistantUrl = null;
    _isConfigured = false;
    notifyListeners();
    _handleAuthStateChanged();
  }

  void _handleAuthStateChanged() {
    _log.info(
        'Handling Auth State Change. AuthState: ${_authService.state}, URL: $_homeAssistantUrl, DeviceID: $_deviceId');

    if (_authService.state != AuthState.authenticated) {
      final wsService = WebSocketService.getInstance();
      if (wsService.isConnected) {
        _log.info(
            'Auth state changed to unauthenticated. Disconnecting WebSocket...');
        Future.microtask(() => wsService.disconnect());
      } else {
        _log.fine(
            'Auth state changed to unauthenticated. WebSocket already disconnected.');
      }
    }
  }
}
