import 'dart:convert';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:logging/logging.dart';

import 'services/websocket_service.dart';

final _log = Logger('RadWebViewController');

abstract class RadWebViewController {
  Future<String?> getCurrentUrl();

  Future<void> navigateToUrl(String url);

  Future<dynamic> evaluateJavascript(String js);

  Future<void> reload();

  static String generateAuthInjectionJs(
    String accessToken,
    String refreshToken,
    int expiresIn,
    String clientId,
    String hassUrl,
  ) {
    final authData = {
      'access_token': accessToken,
      'refresh_token': refreshToken,
      'expires_in': expiresIn,
      'token_type': 'Bearer',
      'clientId': clientId,
      'hassUrl': hassUrl,
      'expires': DateTime.now().millisecondsSinceEpoch + expiresIn * 1000,
    };
    final jsonData = jsonEncode(authData);
    final escapedJson =
        jsonData.replaceAll(r'\', r'\\').replaceAll(r"'", r"\'");

    return '''
      try {
        localStorage.setItem('hassTokens', '$escapedJson');
        console.log('Injected hassTokens via RadWebViewController helper');
      } catch (e) {
        console.error('Error injecting hassTokens:', e);
      }
    ''';
  }

  static String generateDisplaySettingsInjectionJs(
    String deviceId,
    String storageKey,
    bool hideHeader,
    bool hideSidebar,
  ) {
    final settings = {
      'hideHeader': hideHeader,
      'hideSidebar': hideSidebar,
    };
    final settingsJson = jsonEncode(settings);
    final escapedSettingsJson =
        settingsJson.replaceAll(r'\', r'\\').replaceAll(r"'", r"\'");

    return '''
      try {
        localStorage.setItem('$storageKey', '$deviceId');
        localStorage.setItem('remote_assist_display_id', '$deviceId');
        localStorage.setItem('remote_assist_display_settings', '$escapedSettingsJson');
        console.log('Set localStorage[$storageKey] = $deviceId and remote_assist_display_settings via RadWebViewController helper');
        if (window.RemoteAssistDisplay) {
            window.RemoteAssistDisplay.run();
        }
      } catch (e) {
        console.error('Error setting device ID or display settings in localStorage:', e);
      }
    ''';
  }

  static Future<void> handleNavigation(
    RadWebViewController controller,
    String target,
    String currentBaseOrigin,
  ) async {
    final Uri targetUri = Uri.tryParse(target) ?? Uri();
    final bool isFullUrl = targetUri.hasScheme &&
        (targetUri.scheme == 'http' || targetUri.scheme == 'https');

    if (isFullUrl) {
      _log.info('Navigating via full load (navigateToUrl) to: $target');
      await controller.navigateToUrl(target);
    } else {
      final String path = target.startsWith('/') ? target : '/$target';
      String? currentWebViewUrl;
      try {
        currentWebViewUrl = await controller.getCurrentUrl();
      } catch (e, s) {
        _log.warning(
            'Error getting current URL for navigation decision: $e', e, s);
        final fullUrl = '$currentBaseOrigin$path';
        _log.warning(
            'Falling back to full load due to error getting current URL: $fullUrl');
        await controller.navigateToUrl(fullUrl);
        return;
      }

      final String currentOrigin =
          currentWebViewUrl != null ? Uri.parse(currentWebViewUrl).origin : '';

      if (currentOrigin == currentBaseOrigin) {
        final escapedPath = path
            .replaceAll(r'\', r'\\')
            .replaceAll(r"'", r"\'")
            .replaceAll(r'"', r'\"');
        final String jsNavigate = '''
          try {
            console.log('Navigating via JS pushState to: $escapedPath');
            history.pushState(null, "", "$escapedPath");
            window.dispatchEvent(new CustomEvent("location-changed"));
          } catch (e) {
            console.error('JS navigation error:', e);
          }
          null;
        ''';
        _log.info('Navigating via JS pushState to: $path');
        try {
          await controller.evaluateJavascript(jsNavigate);
          final newFullUrl = '$currentBaseOrigin$path';
          _log.info('Reporting JS navigation URL change: $newFullUrl');
          WebSocketService.getInstance().updateCurrentUrl(newFullUrl);
        } catch (e, s) {
          _log.severe(
              'Error running JS navigation: $e. Falling back to full load.',
              e,
              s);
          final fullUrl = '$currentBaseOrigin$path';
          await controller.navigateToUrl(fullUrl);
        }
      } else {
        final fullUrl = '$currentBaseOrigin$path';
        _log.warning(
            'Origins mismatch or current URL unknown ($currentOrigin vs $currentBaseOrigin). Navigating via full load to: $fullUrl');
        await controller.navigateToUrl(fullUrl);
      }
    }
  }
}

class AndroidWebViewController implements RadWebViewController {
  final InAppWebViewController controller;
  AndroidWebViewController(this.controller);

  @override
  Future<String?> getCurrentUrl() async {
    final uri = await controller.getUrl();
    return uri?.toString();
  }

  @override
  Future<void> navigateToUrl(String url) async {
    await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  @override
  Future<dynamic> evaluateJavascript(String js) async {
    return await controller.evaluateJavascript(source: js);
  }

  @override
  Future<void> reload() async {
    await controller.reload();
  }
}

class LinuxWebViewController implements RadWebViewController {
  Webview? _linuxWebview;

  void setLinuxWebview(Webview webview) {
    _linuxWebview = webview;
  }

  Webview? get linuxWebview => _linuxWebview;

  @override
  Future<String?> getCurrentUrl() async {
    if (_linuxWebview == null) return null;
    try {
      final currentUrlRaw =
          await _linuxWebview!.evaluateJavaScript('window.location.href');
      String? currentUrl = currentUrlRaw?.trim();
      if (currentUrl != null &&
          currentUrl.startsWith('"') &&
          currentUrl.endsWith('"')) {
        currentUrl = currentUrl.substring(1, currentUrl.length - 1);
      }
      return currentUrl;
    } catch (e, s) {
      _log.warning('Linux error getting current URL via JS: $e', e, s);
      return null;
    }
  }

  @override
  Future<void> navigateToUrl(String url) async {
    _linuxWebview?.launch(url);
  }

  @override
  Future<dynamic> evaluateJavascript(String js) async {
    if (_linuxWebview == null) {
      _log.warning("Linux: Cannot evaluate JS, webview is null.");
      return null;
    }
    try {
      return await _linuxWebview!.evaluateJavaScript(js);
    } catch (e, s) {
      _log.severe("Linux: Error evaluating JS: $e", e, s);
      return null;
    }
  }

  @override
  Future<void> reload() async {
    await _linuxWebview?.reload();
  }
}
