import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'auth_service.dart'; // Import AuthService

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
      ..loadRequest(Uri.parse(widget.url)); // Load dashboard URL directly
  }

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: _controller);
  }
}
