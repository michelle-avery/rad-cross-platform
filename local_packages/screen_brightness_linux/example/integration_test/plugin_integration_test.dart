// This is a basic Flutter integration test.
//
// Since integration tests run in a full Flutter application, they can interact
// with the host side of a plugin implementation, unlike Dart unit tests.
//
// For more information about Flutter integration tests, please see
// https://docs.flutter.dev/cookbook/testing/integration/introduction

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:screen_brightness_linux/screen_brightness_linux.dart';
// TODO(you): Import any other packages you need to test.

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('getSystemBrightness test', (WidgetTester tester) async {
    final ScreenBrightnessLinux plugin = ScreenBrightnessLinux.instance;
    final double? brightness = await plugin.systemBrightness;
    // The value depends on the system, so we just check it's within range.
    // On CI/test environments, there might not be a controllable backlight.
    // So we check if it's null or within 0.0-1.0
    expect(
      brightness == null || (brightness >= 0.0 && brightness <= 1.0),
      isTrue,
    );
  });

  testWidgets('canChangeSystemBrightness test', (WidgetTester tester) async {
    final ScreenBrightnessLinux plugin = ScreenBrightnessLinux.instance;
    final bool canChange = await plugin.canChangeSystemBrightness;
    // This can be true or false depending on the system and permissions.
    // We just check that it returns a boolean.
    expect(canChange, anyOf(isTrue, isFalse));
  });

  // Note: Testing setSystemBrightness and onSystemScreenBrightnessChanged
  // in an automated integration test is complex as it requires:
  // 1. A system with a controllable backlight.
  // 2. Permissions to change brightness.
  // 3. A way to verify the change externally or observe it.
  // These are typically better suited for manual testing on target hardware.
}
