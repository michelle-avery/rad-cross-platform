import 'dart:async';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/auth_service.dart';
import '../services/websocket_service.dart';

class AndroidWebViewWidget extends StatefulWidget {
  final String url;
  final WebViewController? controller;
  final String? accessToken;
  final String? refreshToken;
  final int? expiresIn;
  final void Function()? onSuccess;
  final void Function(String error)? onError;
  final VoidCallback? onWebViewReady;
  const AndroidWebViewWidget({
    super.key,
    required this.url,
    this.controller,
    this.accessToken,
    this.refreshToken,
    this.expiresIn,
    this.onSuccess,
    this.onError,
    this.onWebViewReady,
  });

  @override
  State<AndroidWebViewWidget> createState() => _AndroidWebViewWidgetState();
}

class _AndroidWebViewWidgetState extends State<AndroidWebViewWidget> {
  late final WebViewController _controller;
  bool _successNotified = false;
  bool _tokenInjected = false;
  StreamSubscription<String>? _navigationSubscription;

  @override
  void initState() {
    super.initState();
    print('[AndroidWebViewWidget] Loading URL: \\${widget.url}');
    _controller = widget.controller ?? WebViewController();
    _controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            print('[AndroidWebViewWidget] onPageStarted: \\${url}');
          },
          onPageFinished: (url) async {
            print('[AndroidWebViewWidget] onPageFinished: \\${url}');
            if (!_tokenInjected &&
                widget.accessToken != null &&
                widget.refreshToken != null &&
                widget.expiresIn != null) {
              final js = AuthService.generateTokenInjectionJs(
                widget.accessToken!,
                widget.refreshToken!,
                widget.expiresIn!,
                widget.url,
                widget.url,
              );
              print('[AndroidWebViewWidget] Injecting JS...');
              await _controller.runJavaScript(js);
              _tokenInjected = true;
              print('[AndroidWebViewWidget] JS Injected.');
              print(
                  '[AndroidWebViewWidget] Calling onWebViewReady callback...');
              widget.onWebViewReady?.call();
            }
            print(
                '[AndroidWebViewWidget] Reporting URL change to WebSocket: $url');
            WebSocketService.getInstance().updateCurrentUrl(url);

            if (!_successNotified) {
              _successNotified = true;
              widget.onSuccess?.call();
            }
          },
          onWebResourceError: (error) {
            print(
                '[AndroidWebViewWidget] onWebResourceError: \\${error.description}');
            if (!_successNotified) {
              _successNotified = true;
              widget.onError?.call(error.description);
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));

    _navigationSubscription =
        WebSocketService.getInstance().navigationTargetStream.listen(
      (target) async {
        print('[AndroidWebViewWidget] Received navigation target: $target');
        if (!mounted) {
          print(
              '[AndroidWebViewWidget] Widget unmounted, skipping navigation.');
          return;
        }

        final Uri targetUri = Uri.tryParse(target) ?? Uri();
        final bool isFullUrl = targetUri.hasScheme &&
            (targetUri.scheme == 'http' || targetUri.scheme == 'https');

        if (isFullUrl) {
          // Handle navigate_url command (full URL)
          print(
              '[AndroidWebViewWidget] Navigating via loadRequest to: $target');
          _controller.loadRequest(Uri.parse(target));
        } else {
          // Handle navigate command (relative path)
          final String path = target.startsWith('/') ? target : '/$target';
          final String baseOrigin = Uri.parse(widget.url).origin;
          String? currentWebViewUrl = await _controller.currentUrl();
          final String currentOrigin = currentWebViewUrl != null
              ? Uri.parse(currentWebViewUrl).origin
              : '';

          if (currentOrigin == baseOrigin) {
            // Use JS pushState for faster navigation within the same origin
            final String jsNavigate = '''
              async function browser_navigate(path) {
                  if (!path) return;
                  console.log('Navigating via JS pushState to:', path);
                  history.pushState(null, "", path);
                  window.dispatchEvent(new CustomEvent("location-changed"));
              }
              browser_navigate("$path");
            ''';
            print(
                '[AndroidWebViewWidget] Navigating via JS pushState to: $path');
            try {
              await _controller.runJavaScript(jsNavigate);
              // Manually update the server as onPageFinished won't trigger
              final newFullUrl = '$baseOrigin$path';
              print(
                  '[AndroidWebViewWidget] Reporting JS navigation URL change: $newFullUrl');
              WebSocketService.getInstance().updateCurrentUrl(newFullUrl);
            } catch (e) {
              print(
                  '[AndroidWebViewWidget] Error running JS navigation: $e. Falling back to loadRequest.');
              final fullUrl = '$baseOrigin$path';
              _controller.loadRequest(Uri.parse(fullUrl));
            }
          } else {
            // Fallback to full load if origins don't match or current URL is unknown
            final fullUrl = '$baseOrigin$path';
            print(
                '[AndroidWebViewWidget] Origins mismatch or current URL unknown. Navigating via loadRequest to: $fullUrl');
            _controller.loadRequest(Uri.parse(fullUrl));
          }
        }
      },
      onError: (error) {
        print('[AndroidWebViewWidget] Error on navigation stream: $error');
      },
    );
  }

  @override
  void dispose() {
    _navigationSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: _controller);
  }
}
