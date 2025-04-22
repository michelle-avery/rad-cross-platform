import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class AndroidWebViewWidget extends StatefulWidget {
  final String url;
  final void Function()? onSuccess;
  final void Function(String error)? onError;
  const AndroidWebViewWidget(
      {super.key, required this.url, this.onSuccess, this.onError});

  @override
  State<AndroidWebViewWidget> createState() => _AndroidWebViewWidgetState();
}

class _AndroidWebViewWidgetState extends State<AndroidWebViewWidget> {
  late final WebViewController _controller;
  bool _successNotified = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) {
            if (!_successNotified) {
              _successNotified = true;
              widget.onSuccess?.call();
            }
          },
          onWebResourceError: (error) {
            if (!_successNotified) {
              _successNotified = true;
              widget.onError?.call(error.description);
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: _controller);
  }
}
