import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

class ScreenBrightnessLinux {
  static const MethodChannel _methodChannel = MethodChannel(
    'screen_brightness_linux',
  );
  static const EventChannel _eventChannel = EventChannel(
    'screen_brightness_linux_stream',
  );

  static final ScreenBrightnessLinux instance = ScreenBrightnessLinux._();

  ScreenBrightnessLinux._();

  Stream<double>? _onBrightnessChanged;

  Future<double> get systemBrightness async {
    if (!Platform.isLinux) {
      throw UnsupportedError('This plugin only supports Linux.');
    }
    final double? brightness = await _methodChannel.invokeMethod<double>(
      'getSystemBrightness',
    );
    return brightness ?? 0.0;
  }

  Future<void> setSystemBrightness(double brightness) async {
    if (!Platform.isLinux) {
      throw UnsupportedError('This plugin only supports Linux.');
    }
    if (brightness < 0.0 || brightness > 1.0) {
      throw ArgumentError(
        'Brightness value must be between 0.0 and 1.0 (inclusive).',
      );
    }
    await _methodChannel.invokeMethod<void>('setSystemBrightness', {
      'brightness': brightness,
    });
  }

  Future<bool> get canChangeSystemBrightness async {
    if (!Platform.isLinux) {
      throw UnsupportedError('This plugin only supports Linux.');
    }
    final bool? canChange = await _methodChannel.invokeMethod<bool>(
      'canChangeSystemBrightness',
    );
    return canChange ?? false;
  }

  Stream<double> get onSystemScreenBrightnessChanged {
    if (!Platform.isLinux) {
      throw UnsupportedError('This plugin only supports Linux.');
    }
    _onBrightnessChanged ??= _eventChannel.receiveBroadcastStream().map(
      (event) => event as double,
    );
    return _onBrightnessChanged!;
  }
}
