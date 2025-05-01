import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:logging/logging.dart';
import '../oauth_config.dart';

final _log = Logger('OAuthWebViewScreen');

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
  bool _isHandlingCode = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            _log.fine('Navigating to: ${request.url}');
            final uri = Uri.parse(request.url);
            if (uri.scheme == OAuthConfig.scheme &&
                uri.host == OAuthConfig.callbackPath) {
              final code = uri.queryParameters['code'];
              final state = uri.queryParameters['state'];
              _log.info('Intercepted redirect: code=$code, state=$state');

              if (code != null && state != null && !_isHandlingCode) {
                _isHandlingCode = true;
                widget.onAuthCode(code, state);
                Future.microtask(() {
                  if (mounted) {
                    Navigator.of(context).pop();
                  }
                });
                return NavigationDecision.prevent;
              }
            }
            return NavigationDecision.navigate;
          },
          onPageFinished: (String url) {
            _log.info('Page finished loading: $url');
          },
          onWebResourceError: (WebResourceError error) {
            _log.severe(
                'Web Resource Error: ${error.description}, URL: ${error.url}, Type: ${error.errorType}',
                error);
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                    content: Text('Error loading page: ${error.description}')),
              );
            }
          },
        ),
      );

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
