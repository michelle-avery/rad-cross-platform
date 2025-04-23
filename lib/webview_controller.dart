import 'dart:io';
import 'package:webview_flutter/webview_flutter.dart';

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
RadWebViewController createWebViewController(
    {WebViewController? androidController}) {
  if (Platform.isAndroid) {
    if (androidController == null)
      throw ArgumentError('WebViewController required for Android');
    return AndroidWebViewController(androidController);
  } else if (Platform.isLinux) {
    return LinuxWebViewController();
  } else {
    throw UnsupportedError('Platform not supported');
  }
}

/// Stub for Android implementation.
class AndroidWebViewController implements RadWebViewController {
  final WebViewController controller;
  AndroidWebViewController(this.controller);

  @override
  Future<String?> getCurrentUrl() async => await controller.currentUrl();

  @override
  Future<void> navigateToUrl(String url) async =>
      await controller.loadRequest(Uri.parse(url));

  @override
  Future<void> evaluateJavascript(String js) async =>
      await controller.runJavaScript(js);

  @override
  Future<void> reload() async => await controller.reload();
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
