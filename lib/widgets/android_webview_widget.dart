import 'dart:async'; // Import async for Timer
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:logging/logging.dart'; // Import logging
import 'package:radcxp/screens/log_viewer_screen.dart'; // Import LogViewerScreen
// Import WebSocketService directly or via alias if needed elsewhere
import 'package:radcxp/services/websocket_service.dart';

// Logger instance
final _log = Logger('AndroidWebViewWidget');

class AndroidWebViewWidget extends StatefulWidget {
  final String initialUrl;
  // Callback when a page finishes loading
  final void Function(String url)? onPageFinished;

  const AndroidWebViewWidget({
    super.key,
    required this.initialUrl,
    this.onPageFinished,
  });

  @override
  State<AndroidWebViewWidget> createState() => _AndroidWebViewWidgetState();
}

class _AndroidWebViewWidgetState extends State<AndroidWebViewWidget> {
  InAppWebViewController? _androidController;
  final Set<int> _activePointers = {};
  StreamSubscription<String>?
      _navigationSubscription; // Add navigation listener
  Timer? _threeFingerTapTimer;
  bool _potentialThreeFingerTap = false;
  final Duration _threeFingerTapTimeout =
      const Duration(milliseconds: 300); // Timeout for tap gesture

  @override
  void initState() {
    super.initState();
    // Listen for navigation commands from WebSocketService
    _navigationSubscription =
        WebSocketService.getInstance().navigationTargetStream.listen(
      (target) async {
        _log.info('Received navigation target: $target');
        if (!mounted || _androidController == null) {
          _log.warning(
              'Widget unmounted or controller null, skipping navigation.');
          return;
        }

        final Uri targetUri = Uri.tryParse(target) ?? Uri();
        final bool isFullUrl = targetUri.hasScheme &&
            (targetUri.scheme == 'http' || targetUri.scheme == 'https');

        if (isFullUrl) {
          // Handle navigate_url command (full URL)
          _log.info('Navigating via loadUrl to: $target');
          _androidController!
              .loadUrl(urlRequest: URLRequest(url: WebUri(target)));
        } else {
          // Handle navigate command (relative path)
          final String path = target.startsWith('/') ? target : '/$target';
          final WebUri? currentUri = await _androidController!.getUrl();
          // Determine base origin from initialUrl or current URL if available
          final String baseOrigin =
              currentUri?.origin ?? Uri.parse(widget.initialUrl).origin;

          // Use JS pushState for potentially faster navigation within the same origin
          // InAppWebView might handle this better, but explicit JS can be fallback
          final String jsNavigate = '''
            async function browser_navigate(path) {
                if (!path) return;
                console.log('Navigating via JS pushState to:', path);
                history.pushState(null, "", path);
                // Consider dispatching a custom event if needed by the web app
                // window.dispatchEvent(new CustomEvent("location-changed"));
            }
            browser_navigate("$path");
          ''';
          _log.info('Attempting navigation via JS pushState to: $path');
          try {
            await _androidController!.evaluateJavascript(source: jsNavigate);
            // Manually update the server as onLoadStop might not trigger for pushState
            final newFullUrl = '$baseOrigin$path';
            _log.info('Reporting JS navigation URL change: $newFullUrl');
            WebSocketService.getInstance().updateCurrentUrl(newFullUrl);
          } catch (e, stackTrace) {
            _log.severe(
                'Error running JS navigation: $e. Falling back to loadUrl.',
                e,
                stackTrace);
            final fullUrl = '$baseOrigin$path';
            _androidController!
                .loadUrl(urlRequest: URLRequest(url: WebUri(fullUrl)));
          }
        }
      },
      onError: (error, stackTrace) {
        _log.severe('Error on navigation stream.', error, stackTrace);
      },
    );
  }

  @override
  void dispose() {
    _threeFingerTapTimer?.cancel();
    _navigationSubscription?.cancel(); // Cancel subscription
    super.dispose();
  }

  void _handlePointerDown(PointerDownEvent event) {
    _activePointers.add(event.pointer);
    _log.fine(
        'Pointer down: ${event.pointer}. Active pointers: ${_activePointers.length}');

    // Start tracking for a potential three-finger tap only when exactly 3 fingers are down
    if (_activePointers.length == 3) {
      _potentialThreeFingerTap = true;
      _threeFingerTapTimer?.cancel(); // Cancel any previous timer
      _threeFingerTapTimer = Timer(_threeFingerTapTimeout, () {
        _log.fine(
            'Three-finger tap timed out (fingers held too long or not lifted).');
        _potentialThreeFingerTap = false; // Reset if fingers held too long
        // Don't clear pointers here, let onPointerUp handle it
      });
      _log.fine('Potential three-finger tap started.');
    } else {
      // If more or fewer than 3 fingers are down initially, it's not a valid start
      // Or if another finger is added after the initial 3
      _potentialThreeFingerTap = false;
      _threeFingerTapTimer?.cancel();
      if (_activePointers.length > 3) {
        _log.fine('More than 3 fingers detected, cancelling potential tap.');
      }
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    int pointersBeforeUp = _activePointers.length;
    _activePointers.remove(event.pointer);
    _log.fine(
        'Pointer up: ${event.pointer}. Active pointers after removal: ${_activePointers.length}');

    // Check if this 'up' event completes a valid three-finger tap
    if (_potentialThreeFingerTap &&
        pointersBeforeUp == 3 &&
        _activePointers.isEmpty) {
      // This means the 3rd finger was lifted within the timeout, completing the tap sequence
      _threeFingerTapTimer?.cancel(); // Cancel the timeout timer
      _log.info('Three-finger tap detected!');
      _potentialThreeFingerTap = false; // Reset flag

      // --- Show log viewer ---
      // Ensure context is still valid before navigating
      if (mounted) {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (context) => const LogViewerScreen(),
        ));
      }
      // -----------------------
    } else if (_activePointers.isEmpty) {
      // All fingers lifted, but it wasn't a valid 3-finger tap sequence that just completed
      _potentialThreeFingerTap = false;
      _threeFingerTapTimer?.cancel();
      _log.fine('All pointers up, but not a valid three-finger tap.');
    }
    // If some fingers are still down, do nothing until the last one is lifted
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _log.warning('Pointer cancel: ${event.pointer}');
    _activePointers.remove(event.pointer);
    // If a potential tap was in progress, cancel it
    if (_potentialThreeFingerTap) {
      _log.warning(
          'Cancelling potential three-finger tap due to pointer cancel.');
      _potentialThreeFingerTap = false;
      _threeFingerTapTimer?.cancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _handlePointerDown,
      onPointerUp: _handlePointerUp,
      onPointerCancel: _handlePointerCancel,
      // AbsorbPointer prevents the Listener from blocking webview interaction,
      // but we need the pointer events. Behavior 'translucent' allows events
      // to pass through to the webview *and* be caught by the Listener.
      behavior: HitTestBehavior.translucent,
      child: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(widget.initialUrl)),
        initialSettings: InAppWebViewSettings(
          useHybridComposition: true, // Essential for AndroidView interaction
          javaScriptEnabled: true,
          transparentBackground: true,
          // Add other settings as needed
        ),
        gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
          Factory<VerticalDragGestureRecognizer>(
            () => VerticalDragGestureRecognizer(),
          ),
          Factory<HorizontalDragGestureRecognizer>(
            () => HorizontalDragGestureRecognizer(),
          ),
          // Add other recognizers if necessary, e.g., ScaleGestureRecognizer
        },
        onWebViewCreated: (controller) {
          _androidController = controller;
          _log.info('Android InAppWebViewController created.');
        },
        onLoadStop: (controller, url) async {
          final currentUrl = url?.toString() ?? '';
          _log.info('Android WebView finished loading: $currentUrl');
          // Notify parent widget via callback
          widget.onPageFinished?.call(currentUrl);
          // Also update WebSocket service
          WebSocketService.getInstance().updateCurrentUrl(currentUrl);
        },
        onProgressChanged: (controller, progress) {
          // Handle progress updates if needed
        },
        onReceivedHttpError: (controller, request, errorResponse) {
          _log.severe(
              'HTTP Error: ${errorResponse.statusCode} for ${request.url}');
        },
        onReceivedError: (controller, request, error) {
          _log.severe(
              'Load Error: ${error.type} ${error.description} for ${request.url}');
        },
        // Add other callbacks as needed (e.g., onConsoleMessage)
        onConsoleMessage: (controller, consoleMessage) {
          _log.fine(
              '[WebView Console] ${consoleMessage.messageLevel}: ${consoleMessage.message}');
        },
      ),
    );
  }
}
