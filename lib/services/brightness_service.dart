import 'dart:async';
import 'dart:io' show Platform;

import 'package:logging/logging.dart';
import 'package:screen_brightness/screen_brightness.dart' as android_brightness;
import 'package:screen_brightness_linux/screen_brightness_linux.dart'
    as linux_brightness;

final _log = Logger('BrightnessService');

class BrightnessService {
  final StreamController<double> _brightnessChangedController =
      StreamController<double>.broadcast();
  StreamSubscription? _linuxBrightnessSubscription;

  BrightnessService() {
    if (Platform.isLinux) {
      try {
        _linuxBrightnessSubscription = linux_brightness
            .ScreenBrightnessLinux.instance.onSystemScreenBrightnessChanged
            .listen((brightness) {
          _log.fine('Linux system brightness changed event: $brightness');
          _brightnessChangedController.add(brightness);
        }, onError: (error) {
          _log.warning(
              'Error listening to Linux system brightness changes: $error');
        });
      } catch (e) {
        _log.severe(
            'Failed to subscribe to Linux brightness changes on init: $e');
      }
    }
  }

  Stream<double> get onBrightnessChanged => _brightnessChangedController.stream;

  Future<double> getCurrentBrightness() async {
    try {
      if (Platform.isAndroid) {
        return await android_brightness.ScreenBrightness().current;
      } else if (Platform.isLinux) {
        return await linux_brightness
            .ScreenBrightnessLinux.instance.systemBrightness;
      } else {
        _log.warning('Unsupported platform for getCurrentBrightness');
        return 1.0;
      }
    } catch (e, s) {
      _log.severe('Error getting current brightness: $e', e, s);
      return 1.0;
    }
  }

  Future<void> setBrightness(double brightness) async {
    final clampedBrightness = brightness.clamp(0.0, 1.0);
    _log.info('Setting brightness to: $clampedBrightness');
    try {
      if (Platform.isAndroid) {
        await android_brightness.ScreenBrightness()
            .setScreenBrightness(clampedBrightness);
      } else if (Platform.isLinux) {
        await linux_brightness.ScreenBrightnessLinux.instance
            .setSystemBrightness(clampedBrightness);
      } else {
        _log.warning('Unsupported platform for setBrightness');
      }
      // Manually emit the change for listeners, as Android plugin might not emit for programmatic changes.
      _brightnessChangedController.add(clampedBrightness);
    } catch (e, s) {
      _log.severe('Error setting brightness: $e', e, s);
    }
  }

  Future<bool> get isPlatformSupported async {
    try {
      if (Platform.isAndroid) {
        return true;
      } else if (Platform.isLinux) {
        return await linux_brightness
            .ScreenBrightnessLinux.instance.canChangeSystemBrightness;
      }
      return false;
    } catch (e) {
      _log.warning(
          'Error checking if platform is supported for brightness: $e');
      return false;
    }
  }

  void dispose() {
    _log.fine('Disposing BrightnessService');
    _linuxBrightnessSubscription?.cancel();
    _brightnessChangedController.close();
  }
}
