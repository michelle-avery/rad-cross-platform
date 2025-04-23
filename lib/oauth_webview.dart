import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'oauth_config.dart';
import 'app_state_provider.dart';
import 'auth_service.dart';

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

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) async {
            print('[OAuthWebView] Navigating to: \\${request.url}');
            final uri = Uri.parse(request.url);
            if (uri.scheme == OAuthConfig.scheme &&
                uri.host == OAuthConfig.callbackPath) {
              final code = uri.queryParameters['code'];
              final state = uri.queryParameters['state'];
              print(
                  '[OAuthWebView] Intercepted redirect: code=\\${code}, state=\\${state}');
              if (code != null && state != null) {
                final authService =
                    Provider.of<AuthService>(context, listen: false);
                final appState =
                    Provider.of<AppStateProvider>(context, listen: false);
                authService.handleAuthCode(code, state).then((_) async {
                  if (authService.hassUrl != null) {
                    await appState.setHomeAssistantUrl(authService.hassUrl!);
                  }
                });
                Navigator.of(context).pop();
                return NavigationDecision.prevent;
              }
            }
            return NavigationDecision.navigate;
          },
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Login to Home Assistant')),
      body: WebViewWidget(
        controller: _controller..loadRequest(Uri.parse(widget.authUrl)),
      ),
    );
  }
}
