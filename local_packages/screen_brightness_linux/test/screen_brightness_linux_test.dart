import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_brightness_linux/screen_brightness_linux.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenBrightnessLinux screenBrightnessLinux;
  final List<MethodCall> log = <MethodCall>[];

  setUp(() {
    screenBrightnessLinux = ScreenBrightnessLinux.instance;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('screen_brightness_linux'),
          (MethodCall methodCall) async {
            log.add(methodCall);
            switch (methodCall.method) {
              case 'getSystemBrightness':
                return 0.5; // Mock value
              case 'setSystemBrightness':
                return null;
              case 'canChangeSystemBrightness':
                return true; // Mock value
              default:
                return null;
            }
          },
        );
    // For EventChannel
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('screen_brightness_linux_stream'),
          (MethodCall methodCall) async {
            switch (methodCall.method) {
              case 'listen':
                // Simulate emitting an event, or handle as needed for tests
                // For now, just acknowledge listen
                Future.delayed(Duration.zero, () {
                  TestDefaultBinaryMessengerBinding
                      .instance
                      .defaultBinaryMessenger
                      .handlePlatformMessage(
                        'screen_brightness_linux_stream',
                        const StandardMethodCodec().encodeSuccessEnvelope(0.75),
                        (ByteData? data) {},
                      );
                });
                return null;
              case 'cancel':
                return null;
              default:
                return null;
            }
          },
        );
    log.clear();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('screen_brightness_linux'),
          null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('screen_brightness_linux_stream'),
          null,
        );
  });

  test('getSystemBrightness', () async {
    final brightness = await screenBrightnessLinux.systemBrightness;
    expect(brightness, 0.5);
    expect(log, <Matcher>[
      isMethodCall('getSystemBrightness', arguments: null),
    ]);
  });

  test('setSystemBrightness', () async {
    await screenBrightnessLinux.setSystemBrightness(0.8);
    expect(log, <Matcher>[
      isMethodCall('setSystemBrightness', arguments: {'brightness': 0.8}),
    ]);
  });

  test('canChangeSystemBrightness', () async {
    final canChange = await screenBrightnessLinux.canChangeSystemBrightness;
    expect(canChange, true);
    expect(log, <Matcher>[
      isMethodCall('canChangeSystemBrightness', arguments: null),
    ]);
  });

  test('onSystemScreenBrightnessChanged', () async {
    final stream = screenBrightnessLinux.onSystemScreenBrightnessChanged;
    expectLater(stream, emits(0.75));
  });
}
