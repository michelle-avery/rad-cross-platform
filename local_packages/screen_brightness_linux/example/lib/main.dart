import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:screen_brightness_linux/screen_brightness_linux.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  double _systemBrightness = 0.0;
  bool _canChangeBrightness = false;
  StreamSubscription<double>? _brightnessSubscription;

  final _screenBrightnessLinux = ScreenBrightnessLinux.instance;

  @override
  void initState() {
    super.initState();
    initPlatformState();
  }

  @override
  void dispose() {
    _brightnessSubscription?.cancel();
    super.dispose();
  }

  Future<void> initPlatformState() async {
    double systemBrightness;
    bool canChangeBrightness;

    try {
      systemBrightness = await _screenBrightnessLinux.systemBrightness;
      canChangeBrightness =
          await _screenBrightnessLinux.canChangeSystemBrightness;
    } on PlatformException {
      systemBrightness = 0.0;
      canChangeBrightness = false;
    }

    if (!mounted) return;

    setState(() {
      _systemBrightness = systemBrightness;
      _canChangeBrightness = canChangeBrightness;
    });

    _brightnessSubscription = _screenBrightnessLinux
        .onSystemScreenBrightnessChanged
        .listen((brightness) {
          if (!mounted) return;
          setState(() {
            _systemBrightness = brightness;
          });
        });
  }

  Future<void> _setBrightness(double brightness) async {
    try {
      await _screenBrightnessLinux.setSystemBrightness(brightness);
      // After setting, re-fetch to confirm or rely on stream
      // For simplicity, we'll rely on the stream to update _systemBrightness
    } on PlatformException catch (e) {
      debugPrint("Failed to set brightness: '${e.message}'.");
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Screen Brightness Linux Example')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text('System Brightness: $_systemBrightness'),
                if (_canChangeBrightness)
                  Slider(
                    value: _systemBrightness,
                    min: 0.0,
                    max: 1.0,
                    onChanged: (value) {
                      // Optimistically update UI, actual value comes from stream
                      setState(() {
                        _systemBrightness = value;
                      });
                    },
                    onChangeEnd: (value) {
                      _setBrightness(value);
                    },
                  )
                else
                  const Text(
                    'Cannot change system brightness (permissions or no backlight device).',
                  ),
                const SizedBox(height: 20),
                Text('Can change brightness: $_canChangeBrightness'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
