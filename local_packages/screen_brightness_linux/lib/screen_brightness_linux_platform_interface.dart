import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'screen_brightness_linux_method_channel.dart';

abstract class ScreenBrightnessLinuxPlatform extends PlatformInterface {
  /// Constructs a ScreenBrightnessLinuxPlatform.
  ScreenBrightnessLinuxPlatform() : super(token: _token);

  static final Object _token = Object();

  static ScreenBrightnessLinuxPlatform _instance = MethodChannelScreenBrightnessLinux();

  /// The default instance of [ScreenBrightnessLinuxPlatform] to use.
  ///
  /// Defaults to [MethodChannelScreenBrightnessLinux].
  static ScreenBrightnessLinuxPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [ScreenBrightnessLinuxPlatform] when
  /// they register themselves.
  static set instance(ScreenBrightnessLinuxPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
