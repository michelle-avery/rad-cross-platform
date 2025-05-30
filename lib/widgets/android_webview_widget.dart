import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';

import '../oauth_config.dart';
import '../providers/app_state_provider.dart';
import '../screens/settings_screen.dart';
import '../services/auth_service.dart';
import '../services/websocket_service.dart';
import '../webview_controller.dart';

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
  InAppWebViewController? _nativeController;
  AndroidWebViewController? _radController;
  StreamSubscription<String>? _navigationSubscription;
  bool _initialAuthCallbackReloadPending = true;

  @override
  void initState() {
    super.initState();
    _navigationSubscription =
        WebSocketService.getInstance().navigationTargetStream.listen(
      (target) async {
        _log.info('Received Android navigation target: $target');
        if (!mounted || _radController == null) {
          _log.warning(
              'Android widget unmounted or Rad controller null, skipping navigation.');
          return;
        }

        final String baseOrigin = Uri.parse(widget.initialUrl).origin;

        await RadWebViewController.handleNavigation(
          controller: _radController!,
          target: target,
          currentBaseOrigin: baseOrigin,
          refreshSignal: refreshSignal,
        );
      },
      onError: (error, stackTrace) {
        _log.severe('Error on Android navigation stream.', error, stackTrace);
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
    final bool isDebug = kDebugMode;

    return Stack(
      children: [
        InAppWebView(
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
            _nativeController = controller;
            _radController = AndroidWebViewController(controller);
            _log.info('Android InAppWebViewController created and wrapped.');

            _nativeController!.addJavaScriptHandler(
                handlerName: 'threeFingerTapHandler',
                callback: (args) {
                  _log.info(
                      'JavaScript handler "threeFingerTapHandler" called!');
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
            _log.info(
                'Android WebView finished loading: $currentUrl. Reload pending: $_initialAuthCallbackReloadPending');

            if (_initialAuthCallbackReloadPending) {
              _log.info(
                  'Initial load with auth_callback=1. Injecting tokens and preparing for reload.');
              await _injectAuthTokensWithHelper(controller);
              _injectDisplaySettingsWithHelper(controller);
              _injectGestureDetectionScript(controller);

              _log.info('Triggering reload...');
              await controller.reload();
              if (mounted) {
                setState(() {
                  _initialAuthCallbackReloadPending = false;
                });
              } else {
                _initialAuthCallbackReloadPending = false;
              }
              _log.info(
                  'Reload triggered. _initialAuthCallbackReloadPending set to false.');
            } else {
              _log.info(
                  'Page loaded after initial reload. Calling onPageFinished and re-injecting settings/gestures.');

              widget.onPageFinished?.call(currentUrl);
              WebSocketService.getInstance().updateCurrentUrl(currentUrl);

              _injectDisplaySettingsWithHelper(controller);
              _injectGestureDetectionScript(controller);
            }
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
        ),
        if (isDebug)
          Positioned(
            top: 10.0,
            right: 10.0,
            child: FloatingActionButton(
              mini: true,
              tooltip: 'Open Settings (Debug)',
              onPressed: () {
                _log.info('Debug settings button pressed.');
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (context) => const SettingsScreen(),
                ));
              },
              child: const Icon(Icons.settings),
            ),
          ),
      ],
    );
  }

  void _injectDisplaySettingsWithHelper(InAppWebViewController controller) {
    if (!mounted) return;

    final appState = Provider.of<AppStateProvider>(context, listen: false);
    final deviceId = appState.deviceId;
    final deviceStorageKey = WebSocketService.getInstance().deviceStorageKey;

    if (deviceId == null) {
      _log.warning("Cannot inject display settings script: deviceId is null.");
      return;
    }

    final String jsCode =
        RadWebViewController.generateDisplaySettingsInjectionJs(
      deviceId,
      deviceStorageKey,
      appState.hideHeader,
      appState.hideSidebar,
    );

    controller.evaluateJavascript(source: jsCode).then((result) {
      _log.info('JavaScript display settings script injected via helper.');
    }).catchError((error) {
      _log.severe(
          'Error injecting JavaScript display settings script via helper: $error');
    });
  }

  Future<void> _injectAuthTokensWithHelper(
      InAppWebViewController controller) async {
    if (!mounted) return;
    _log.info('Attempting to inject auth tokens via helper...');

    final authService = Provider.of<AuthService>(context, listen: false);
    final tokens = authService.tokens;
    final hassUrl = authService.hassUrl;

    if (tokens != null && hassUrl != null) {
      final accessToken = tokens['access_token'] as String?;
      final refreshToken = tokens['refresh_token'] as String?;
      final expiresIn = tokens['expires_in'] as int?;
      final clientId = OAuthConfig.buildClientId(hassUrl);

      if (accessToken != null && refreshToken != null && expiresIn != null) {
        final String authJs = RadWebViewController.generateAuthInjectionJs(
          accessToken,
          refreshToken,
          expiresIn,
          clientId,
          hassUrl,
        );

        try {
          await controller.evaluateJavascript(source: authJs);
          _log.info('JavaScript auth tokens injected via helper.');
        } catch (error) {
          _log.severe(
              'Error injecting JavaScript auth tokens via helper: $error');
        }
      } else {
        _log.warning(
            "Cannot inject auth tokens: Missing token details (access, refresh, or expiry).");
      }
    } else {
      _log.warning(
          "Cannot inject auth tokens: No tokens or hassUrl available from AuthService.");
    }
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
