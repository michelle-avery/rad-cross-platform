import 'dart:async'; // Import async
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/auth_service.dart';
import '../services/websocket_service.dart'; // Import WebSocketService

class AndroidWebViewWidget extends StatefulWidget {
  final String url;
  final WebViewController? controller;
  final String? accessToken;
  final String? refreshToken;
  final int? expiresIn;
  final void Function()? onSuccess;
  final void Function(String error)? onError;
  const AndroidWebViewWidget({
    super.key,
    required this.url,
    this.controller,
    this.accessToken,
    this.refreshToken,
    this.expiresIn,
    this.onSuccess,
    this.onError,
  });

  @override
  State<AndroidWebViewWidget> createState() => _AndroidWebViewWidgetState();
}

class _AndroidWebViewWidgetState extends State<AndroidWebViewWidget> {
  late final WebViewController _controller;
  bool _successNotified = false;
  bool _tokenInjected = false;
  StreamSubscription<String>?
      _navigationSubscription; // Add subscription variable

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
            // Use the centralized JS generation method
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
            }
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
      ..loadRequest(Uri.parse(widget.url)); // Load initial base URL

    // Subscribe to navigation events from WebSocketService
    _navigationSubscription =
        WebSocketService.getInstance().navigationTargetStream.listen(
      (dashboardPath) {
        print(
            '[AndroidWebViewWidget] Received navigation target: $dashboardPath');
        // Construct the full URL
        // Ensure no double slashes and correct base URL usage
        String baseUrl = widget.url.endsWith('/')
            ? widget.url.substring(0, widget.url.length - 1)
            : widget.url;
        String path =
            dashboardPath.startsWith('/') ? dashboardPath : '/$dashboardPath';
        final fullUrl = '$baseUrl$path';
        print('[AndroidWebViewWidget] Navigating to: $fullUrl');
        _controller.loadRequest(Uri.parse(fullUrl));
      },
      onError: (error) {
        print('[AndroidWebViewWidget] Error on navigation stream: $error');
      },
    );
  }

  @override
  void dispose() {
    _navigationSubscription?.cancel(); // Cancel subscription on dispose
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: _controller);
  }
}
