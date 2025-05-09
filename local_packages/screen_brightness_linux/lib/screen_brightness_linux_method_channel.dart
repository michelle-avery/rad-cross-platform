import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'screen_brightness_linux_platform_interface.dart';

/// An implementation of [ScreenBrightnessLinuxPlatform] that uses method channels.
class MethodChannelScreenBrightnessLinux extends ScreenBrightnessLinuxPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('screen_brightness_linux');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
