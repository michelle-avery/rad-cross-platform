import 'dart:io';
import 'package:webview_flutter/webview_flutter.dart' as android_webview;
import 'package:desktop_webview_window/desktop_webview_window.dart';

/// Abstract controller for platform-agnostic WebView operations.
abstract class RadWebViewController {
  Future<String?> getCurrentUrl();
  Future<void> navigateToUrl(String url);
  Future<void> evaluateJavascript(String js);
  Future<void> reload();
}

/// Factory to create the correct controller for the current platform.
RadWebViewController createWebViewController(
    {android_webview.WebViewController? androidController}) {
  if (Platform.isAndroid) {
    if (androidController == null)
      throw ArgumentError('WebViewController required for Android');
    return AndroidWebViewController(androidController);
  } else if (Platform.isLinux) {
    // Return the Linux controller instance
    return LinuxWebViewController();
  } else {
    throw UnsupportedError('Platform not supported');
  }
}

/// Implementation for Android using webview_flutter.
class AndroidWebViewController implements RadWebViewController {
  final android_webview.WebViewController controller;
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

/// Implementation for Linux using desktop_webview_window.
class LinuxWebViewController implements RadWebViewController {
  Webview? _linuxWebview;
  String? _currentUrl;

  void setLinuxWebview(Webview webview) {
    _linuxWebview = webview;
  }

  /// Gets the underlying Linux Webview instance. Used internally or for specific Linux tasks.
  Webview? get linuxWebview => _linuxWebview;

  @override
  Future<String?> getCurrentUrl() async {
    // desktop_webview_window doesn't directly expose current URL.
    // Return the locally stored URL or null.
    return _currentUrl;
  }

  @override
  Future<void> navigateToUrl(String url) async {
    _currentUrl = url; // Optimistically update
    // launch returns void, cannot be awaited
    _linuxWebview?.launch(url);
  }

  @override
  Future<String?> evaluateJavascript(String js) async {
    return await _linuxWebview?.evaluateJavaScript(js);
  }

  @override
  Future<void> reload() async {
    await _linuxWebview?.reload();
  }
}
