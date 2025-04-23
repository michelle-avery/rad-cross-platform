import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../oauth_config.dart';

class OAuthWebView extends StatefulWidget {
  final String authUrl;
  final void Function(String code, String state) onAuthCode;

  const OAuthWebView({
    super.key,
    required this.authUrl,
    required this.onAuthCode,
  });

  @override
  State<OAuthWebView> createState() => _OAuthWebViewState();
}

class _OAuthWebViewState extends State<OAuthWebView> {
  late final WebViewController _controller;
  bool _isHandlingCode = false; // Prevent multiple calls

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            print('[OAuthWebViewScreen] Navigating to: ${request.url}');
            final uri = Uri.parse(request.url);
            // Use values from OAuthConfig
            if (uri.scheme == OAuthConfig.scheme &&
                uri.host == OAuthConfig.callbackPath) {
              final code = uri.queryParameters['code'];
              final state = uri.queryParameters['state'];
              print(
                  '[OAuthWebViewScreen] Intercepted redirect: code=$code, state=$state');

              if (code != null && state != null && !_isHandlingCode) {
                _isHandlingCode = true; // Set flag
                // Call the callback provided by AuthScreen
                widget.onAuthCode(code, state);
                // Pop the WebView screen
                // Use Future.microtask to ensure it happens after current build/event cycle
                Future.microtask(() {
                  if (mounted) {
                    Navigator.of(context).pop();
                  }
                });
                return NavigationDecision.prevent; // Stop the redirect
              }
            }
            return NavigationDecision.navigate; // Allow other navigation
          },
          onPageFinished: (String url) {
            print('[OAuthWebViewScreen] Page finished loading: $url');
          },
          onWebResourceError: (WebResourceError error) {
            print(
                '[OAuthWebViewScreen] Web Resource Error: ${error.description}');
            // Optionally show an error to the user or pop the screen
            if (mounted) {
              // Avoid popping immediately if it was just the initial load failing
              // Maybe show a snackbar or dialog
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                    content: Text('Error loading page: ${error.description}')),
              );
              // Consider popping after a delay or if error persists?
              // Navigator.of(context).pop();
            }
          },
        ),
      );

    // Load the initial URL after controller setup
    _controller.loadRequest(Uri.parse(widget.authUrl));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Login to Home Assistant')),
      body: WebViewWidget(
        controller: _controller,
      ),
    );
  }
}
