import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:logging/logging.dart';
import 'package:radcxp/screens/log_viewer_screen.dart';
import 'package:radcxp/screens/settings_screen.dart';
import 'package:radcxp/services/websocket_service.dart';

final _log = Logger('AndroidWebViewWidget');

class AndroidWebViewWidget extends StatefulWidget {
  final String initialUrl;
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
  StreamSubscription<String>? _navigationSubscription;

  @override
  void initState() {
    super.initState();
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
          _log.info('Navigating via loadUrl to: $target');
          _androidController!
              .loadUrl(urlRequest: URLRequest(url: WebUri(target)));
        } else {
          final String path = target.startsWith('/') ? target : '/$target';
          final WebUri? currentUri = await _androidController!.getUrl();
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
    _navigationSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(widget.initialUrl)),
      initialSettings: InAppWebViewSettings(
        useHybridComposition: true,
        javaScriptEnabled: true,
        transparentBackground: true,
      ),
      gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
        Factory<VerticalDragGestureRecognizer>(
          () => VerticalDragGestureRecognizer(),
        ),
        Factory<HorizontalDragGestureRecognizer>(
          () => HorizontalDragGestureRecognizer(),
        ),
      },
      onWebViewCreated: (controller) {
        _androidController = controller;
        _log.info('Android InAppWebViewController created.');

        _androidController!.addJavaScriptHandler(
            handlerName: 'threeFingerTapHandler',
            callback: (args) {
              _log.info('JavaScript handler "threeFingerTapHandler" called!');
              if (mounted) {
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (context) => const SettingsScreen(),
                ));
              } else {
                _log.warning(
                    'Context not mounted, cannot navigate to LogViewerScreen from JS handler.');
              }
            });
        _log.info('Registered JS handler "threeFingerTapHandler".');
      },
      onLoadStop: (controller, url) async {
        final currentUrl = url?.toString() ?? '';
        _log.info('Android WebView finished loading: $currentUrl');
        widget.onPageFinished?.call(currentUrl);
        WebSocketService.getInstance().updateCurrentUrl(currentUrl);

        _injectGestureDetectionScript(controller);
      },
      onProgressChanged: (controller, progress) {},
      onReceivedHttpError: (controller, request, errorResponse) {
        _log.severe(
            'HTTP Error: ${errorResponse.statusCode} for ${request.url}');
      },
      onReceivedError: (controller, request, error) {
        _log.severe(
            'Load Error: ${error.type} ${error.description} for ${request.url}');
      },
      onConsoleMessage: (controller, consoleMessage) {
        _log.fine(
            '[WebView Console] ${consoleMessage.messageLevel}: ${consoleMessage.message}');
      },
    );
  }

  void _injectGestureDetectionScript(InAppWebViewController controller) {
    const String jsCode = '''
      (function() {
        // Prevent multiple initializations
        if (window._threeFingerTapInitialized) {
          console.log('Three-finger tap detector already initialized.');
          return;
        }
        window._threeFingerTapInitialized = true;
        console.log('Initializing three-finger tap detector...');

        let activeTouches = 0;
        let potentialTap = false;
        let tapStartedWithThree = false;
        let tapTimer = null;
        const tapTimeoutMs = 300; // Match Flutter timeout

        function handleTouchStart(event) {
          activeTouches = event.touches.length;
          console.log('touchstart - activeTouches:', activeTouches);

          if (activeTouches === 3) {
            console.log('Potential 3-finger tap START');
            potentialTap = true;
            tapStartedWithThree = true;
            clearTimeout(tapTimer);
            tapTimer = setTimeout(() => {
              console.log('3-finger tap TIMEOUT');
              potentialTap = false;
              tapStartedWithThree = false;
            }, tapTimeoutMs);
          } else {
            // If touches change to something other than 3, cancel potential tap
            if (potentialTap) {
               console.log('Touch count changed to ' + activeTouches + ', cancelling potential tap.');
               potentialTap = false;
               tapStartedWithThree = false;
               clearTimeout(tapTimer);
            }
            // Ensure flag is false if not starting with 3 touches
            tapStartedWithThree = false;
          }
        }

        function handleTouchEnd(event) {
          const touchesBeforeEnd = activeTouches;
          // event.touches tracks remaining touches, not total lifted in this event
          activeTouches = event.touches.length;
          console.log('touchend - touchesBeforeEnd:', touchesBeforeEnd, 'activeTouchesAfter:', activeTouches, 'tapStartedWithThree:', tapStartedWithThree, 'potentialTap:', potentialTap);

          if (potentialTap && tapStartedWithThree && activeTouches === 0) {
            console.log('>>> SUCCESS: 3-finger tap detected via JS! <<<');
            clearTimeout(tapTimer);
            potentialTap = false;
            tapStartedWithThree = false; // <<< RESET FLAG >>>
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              console.log('Calling Flutter handler: threeFingerTapHandler');
              window.flutter_inappwebview.callHandler('threeFingerTapHandler');
            } else {
              console.error('Flutter InAppWebView handler not available.');
            }
          } else if (activeTouches === 0) {
             // All fingers lifted, but not a valid tap sequence
             if (potentialTap || tapStartedWithThree) {
                console.log('All fingers up, but not a valid 3-finger tap sequence. Resetting.');
                potentialTap = false;
                tapStartedWithThree = false;
                clearTimeout(tapTimer);
             }
          }
          // If potentialTap is true but activeTouches > 0, do nothing yet
        }

        function handleTouchCancel(event) {
          console.warn('touchcancel - activeTouches before:', activeTouches);
          activeTouches = event.touches.length; // Update count based on remaining touches
          console.warn('touchcancel - activeTouches after:', activeTouches);
          if (potentialTap || tapStartedWithThree) {
            console.warn('Cancelling potential 3-finger tap due to touchcancel.');
            potentialTap = false;
            tapStartedWithThree = false;
            clearTimeout(tapTimer);
          }
        }

        // Add listeners to the document
        document.addEventListener('touchstart', handleTouchStart, { passive: true });
        document.addEventListener('touchend', handleTouchEnd, { passive: true });
        document.addEventListener('touchcancel', handleTouchCancel, { passive: true });

        console.log('Three-finger tap detector listeners added.');
      })();
    ''';

    controller.evaluateJavascript(source: jsCode).then((result) {
      _log.info('JavaScript gesture detection script injected.');
    }).catchError((error) {
      _log.severe(
          'Error injecting JavaScript gesture detection script: $error');
    });
  }
}
