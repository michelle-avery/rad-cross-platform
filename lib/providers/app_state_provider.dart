import 'dart:io';

import 'package:flutter/material.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/auth_service.dart';
import '../services/websocket_service.dart';
import '../services/brightness_service.dart'; // Added
import 'dart:async'; // Added

final _log = Logger('AppStateProvider');

class AppStateProvider extends ChangeNotifier {
  bool _isConfigured = false;
  String? _homeAssistantUrl;
  String? _deviceId;
  String? _hostName = "Unknown";
  bool? _hideHeader;
  bool? _hideSidebar;
  String? _appVersion;
  double? _currentBrightness; // Added
  double? _storedBrightnessBeforeOff; // Added
  // Timer? _statusUpdateTimer; // Removed
  BrightnessService? _brightnessService; // Added

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
  String? get appVersion => _appVersion;
  double? get currentBrightness => _currentBrightness; // Added

  AppStateProvider(this._authService) {
    _log.fine('Constructor called.');
    _initialize();
  }

  Future<void> _initialize() async {
    _brightnessService = BrightnessService(); // Added
    await _loadSavedState();
    await _loadAppVersion();
    _authService.addListener(_handleAuthStateChanged);
    _handleAuthStateChanged(); // Initial check

    // Initialize brightness
    try {
      if (await _brightnessService!.isPlatformSupported) {
        _currentBrightness = await _brightnessService!.getCurrentBrightness();
        _log.info('Initial brightness loaded: $_currentBrightness');
        _brightnessService!.onBrightnessChanged.listen((brightness) {
          if (_currentBrightness != brightness) {
            _log.info('System brightness changed externally to: $brightness');
            _currentBrightness = brightness;
            notifyListeners();
            _triggerStatusUpdateToHA(); // Added: Send update on external change
          }
        }, onError: (error) {
          _log.warning('Error on brightness changed stream: $error');
        });
      } else {
        _log.info('Brightness control not supported on this platform.');
      }
    } catch (e, s) {
      _log.severe('Error initializing brightness: $e', e, s);
    }
    // _startStatusUpdateTimer(); // Removed
    if (_currentBrightness != null) {
      // Send initial status if brightness was determined
      _triggerStatusUpdateToHA();
    }
    notifyListeners(); // Notify after initial brightness load
  }

  @override
  void dispose() {
    _log.fine('Disposing...');
    _authService.removeListener(_handleAuthStateChanged);
    _brightnessService?.dispose(); // Added
    // _statusUpdateTimer?.cancel(); // Removed
    WebSocketService.getInstance().dispose();
    super.dispose();
  }

  Future<void> _loadSavedState() async {
    final prefs = await SharedPreferences.getInstance();
    _homeAssistantUrl = prefs.getString(_haUrlKey);
    _hideHeader = prefs.getBool(_hideHeaderKey);
    _hideSidebar = prefs.getBool(_hideSidebarKey);
    _deviceId = prefs.getString(_deviceIdKey);
    _log.info(
        'Loaded $_haUrlKey: $_homeAssistantUrl, $_deviceIdKey: $_deviceId, $_hideHeaderKey: $_hideHeader, $_hideSidebarKey: $_hideSidebar');
    _isConfigured = _homeAssistantUrl != null && _homeAssistantUrl!.isNotEmpty;
    _log.info('isConfigured (based on URL): $_isConfigured');
    // No brightness to load from prefs, it's read from system
  }

  Future<void> _loadAppVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      _appVersion = '${packageInfo.version}+${packageInfo.buildNumber}';
      _log.info('Loaded app version: $_appVersion');
    } catch (e, s) {
      _log.severe('Error loading app version: $e', e, s);
      _appVersion = 'Unknown';
    }
  }

  Future<void> configureInitialDeviceId(String? customDeviceId) async {
    if (_deviceId != null && _deviceId!.isNotEmpty) {
      _log.warning(
          'configureInitialDeviceId called, but device ID already exists: $_deviceId');
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    String? finalDeviceId;

    if (customDeviceId != null && customDeviceId.isNotEmpty) {
      finalDeviceId = customDeviceId;
      _log.info('Using provided custom device ID: $finalDeviceId');
    } else {
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
      finalDeviceId = 'rad-$randomID-$_hostName';
      _log.info('Generated new device ID: $finalDeviceId');
    }

    _deviceId = finalDeviceId;
    await prefs.setString(_deviceIdKey, _deviceId!);
    _log.info('Saved device ID: $_deviceId');
    notifyListeners();
  }

  Future<void> setHomeAssistantUrl(String url) async {
    if (_deviceId == null || _deviceId!.isEmpty) {
      _log.severe(
          'Attempted to set Home Assistant URL before device ID was configured!');
      return;
    }

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
      _triggerStatusUpdateToHA(); // Added: Send update on display settings change
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

  // --- Brightness and Status Update Methods ---

  Future<void> setScreenBrightness(String command, [double? value]) async {
    if (_brightnessService == null ||
        !(await _brightnessService!.isPlatformSupported)) {
      _log.warning(
          'Attempted to set brightness, but service is null or platform not supported.');
      return;
    }

    _log.info('Setting screen brightness via command: $command, value: $value');

    try {
      if (command == "off") {
        // Store current brightness only if it's not already 0 (or null)
        if ((_currentBrightness ?? 0.0) > 0.0) {
          _storedBrightnessBeforeOff = _currentBrightness;
          _log.fine(
              'Stored brightness before turning off: $_storedBrightnessBeforeOff');
        } else if (_storedBrightnessBeforeOff == null) {
          // If screen is already off or brightness is 0, and we don't have a stored value,
          // try to get it. If it's 0, default to 1.0 for restore.
          final actualCurrent =
              await _brightnessService!.getCurrentBrightness();
          _storedBrightnessBeforeOff =
              (actualCurrent > 0.0) ? actualCurrent : 1.0;
          _log.fine(
              'Screen was already off or 0, captured/defaulted stored brightness: $_storedBrightnessBeforeOff');
        }
        await _brightnessService!.setBrightness(0.0);
        _currentBrightness = 0.0;
      } else if (command == "on") {
        final restoreTo = _storedBrightnessBeforeOff ?? 1.0;
        _log.fine('Turning screen on. Restoring to: $restoreTo');
        await _brightnessService!.setBrightness(restoreTo);
        _currentBrightness = restoreTo;
        _storedBrightnessBeforeOff = null; // Clear after restoring
      } else if (command == "set" && value != null) {
        final clampedValue = value.clamp(0.0, 1.0);
        await _brightnessService!.setBrightness(clampedValue);
        _currentBrightness = clampedValue;
        // If setting to 0, behave like "off" for storing previous brightness
        if (clampedValue == 0.0 &&
            (_storedBrightnessBeforeOff == null ||
                _storedBrightnessBeforeOff == 0.0)) {
          // This case is tricky. If they set to 0, what was it before?
          // For now, if they explicitly set to 0, we don't auto-store a previous.
          // The "off" command is clearer for that.
        } else if (clampedValue > 0.0) {
          _storedBrightnessBeforeOff = null; // Clear if setting to a value > 0
        }
      } else {
        _log.warning(
            'Invalid setScreenBrightness command: $command or missing value.');
        return;
      }
    } catch (e, s) {
      _log.severe('Error in setScreenBrightness: $e', e, s);
    } finally {
      notifyListeners();
      // Optionally send an immediate status update after a change
      _triggerStatusUpdateToHA(); // Or a more specific "send now"
    }
  }

  void _triggerStatusUpdateToHA() {
    if (_authService.state != AuthState.authenticated ||
        !WebSocketService.getInstance().isConnected) {
      _log.fine(
          'Not authenticated or WebSocket not connected, skipping status update to HA.');
      return;
    }
    _log.fine('Triggering status update to HA via WebSocketService.');
    WebSocketService.getInstance().sendDeviceStatusUpdate();
  }
}
