import 'dart:io';
import 'package:flutter/foundation.dart';

/// Abstract controller for platform-agnostic WebView operations.
abstract class RadWebViewController {
  Future<String?> getCurrentUrl();
  Future<void> navigateToUrl(String url);
  Future<void> evaluateJavascript(String js);
  Future<void> reload();
}

/// Returns true if the app is considered configured (placeholder for now).
bool isConfigured() {
  // TODO: Implement real configuration check
  return true;
}

/// Factory to create the correct controller for the current platform.
RadWebViewController createWebViewController() {
  if (Platform.isAndroid) {
    return AndroidWebViewController();
  } else if (Platform.isLinux) {
    return LinuxWebViewController();
  } else {
    throw UnsupportedError('Platform not supported');
  }
}

/// Stub for Android implementation.
class AndroidWebViewController implements RadWebViewController {
  @override
  Future<String?> getCurrentUrl() async => null;
  @override
  Future<void> navigateToUrl(String url) async {}
  @override
  Future<void> evaluateJavascript(String js) async {}
  @override
  Future<void> reload() async {}
}

/// Stub for Linux implementation.
class LinuxWebViewController implements RadWebViewController {
  @override
  Future<String?> getCurrentUrl() async => null;
  @override
  Future<void> navigateToUrl(String url) async {}
  @override
  Future<void> evaluateJavascript(String js) async {}
  @override
  Future<void> reload() async {}
}
