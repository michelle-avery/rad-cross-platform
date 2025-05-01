import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:logging/logging.dart';

import '../providers/app_state_provider.dart';
import '../services/auth_service.dart';
import '../services/websocket_service.dart';
import '../oauth_config.dart';
import '../webview_controller.dart';
import '../widgets/android_webview_widget.dart';
import 'auth_screen.dart';
import 'settings_screen.dart';

final _log = Logger('AppShell');

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  Webview? _linuxWebview;
  LinuxWebViewController? _linuxRadController;
  bool _linuxInitialLoadAttempted = false;
  bool _linuxTokenInjected = false;
  bool _isWebViewReady = false;
  bool _isWebSocketConnecting = false;
  String? _lastInjectedAccessToken;
  VoidCallback? _isNavigatingListener;
  StreamSubscription<String>? _navigationSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<AuthService>(context, listen: false).loadTokens();
    });
  }

  @override
  void dispose() {
    _closeLinuxWebview();
    super.dispose();
  }

  void _closeLinuxWebview() {
    try {
      if (_linuxWebview != null) {
        _log.info("Closing Linux WebView");
        if (_isNavigatingListener != null) {
          _linuxWebview?.isNavigating.removeListener(_isNavigatingListener!);
          _isNavigatingListener = null;
        }
        _navigationSubscription?.cancel();
        _navigationSubscription = null;
        _linuxWebview?.close();
      }
    } catch (e, s) {
      _log.warning(
          "Error closing Linux Webview (might be already closed): $e", e, s);
    } finally {
      _linuxWebview = null;
      _linuxRadController = null;
      _linuxInitialLoadAttempted = false;
      _linuxTokenInjected = false;
      _isWebViewReady = false;
      _isWebSocketConnecting = false;
      _lastInjectedAccessToken = null;
    }
  }

  Future<void> _injectTokenLinux(AuthService authService) async {
    if (_linuxWebview == null || _linuxRadController == null) {
      _log.warning(
          "Cannot inject token: Linux webview or controller not ready.");
      return;
    }
    final tokens = authService.tokens;
    final hassUrl = authService.hassUrl;
    final deviceId =
        Provider.of<AppStateProvider>(context, listen: false).deviceId;
    final deviceStorageKey = WebSocketService.getInstance().deviceStorageKey;

    if (tokens != null && hassUrl != null && deviceId != null) {
      final accessToken = tokens['access_token'] as String?;
      final refreshToken = tokens['refresh_token'] as String?;
      final expiresIn = tokens['expires_in'] as int?;
      final clientId = OAuthConfig.buildClientId(hassUrl);

      if (accessToken != null && refreshToken != null && expiresIn != null) {
        _log.info(
            "Injecting token into Linux WebView via evaluateJavascript...");
        try {
          final js = AuthService.generateTokenInjectionJs(
            accessToken,
            refreshToken,
            expiresIn,
            clientId,
            hassUrl,
          );
          final deviceIdJs = '''
            try {
              localStorage.setItem('$deviceStorageKey', '$deviceId');
              localStorage.setItem('remote_assist_display_settings', {})
              console.log('Set localStorage[$deviceStorageKey] = $deviceId');
            } catch (e) {
              console.error('Error setting device ID in localStorage:', e);
            }
          ''';
          await _linuxRadController!.evaluateJavascript(js);
          await _linuxRadController!.evaluateJavascript(deviceIdJs);
          _linuxTokenInjected = true;
          _lastInjectedAccessToken = accessToken;
          _log.info(
              "Linux token injected/updated successfully via evaluateJavascript.");
          if (!_isWebViewReady) {
            _signalWebViewReady();
          }
        } catch (e, s) {
          _log.severe("Error injecting token into Linux WebView: $e", e, s);
        }
      } else {
        _log.warning("Cannot inject token: Missing token details.");
        authService.logout();
      }
    } else {
      _log.warning(
          "Cannot inject token: No token, hassUrl, or deviceId available.");
      authService.logout();
    }
  }

  Future<void> _createAndLaunchLinuxWebview(
      String url, AuthService authService) async {
    if (_linuxWebview != null) {
      _log.info("Linux WebView already exists. Closing and recreating.");
      _closeLinuxWebview();
    }

    _linuxInitialLoadAttempted = false;
    _linuxTokenInjected = false;
    _isWebViewReady = false;
    _isWebSocketConnecting = false;
    _lastInjectedAccessToken = null;

    _log.info("Creating Linux WebView window...");
    try {
      _linuxWebview = await WebviewWindow.create(
        configuration: CreateConfiguration(
          openFullscreen: true,
          forceNativeChromeless: true,
        ),
      );
    } catch (e, s) {
      _log.severe("Error creating Linux WebView: $e", e, s);
      return;
    }

    _log.info("Linux WebView created. Setting up callbacks.");
    _linuxRadController = LinuxWebViewController();
    _linuxRadController!.setLinuxWebview(_linuxWebview!);

    _navigationSubscription?.cancel();
    _navigationSubscription =
        WebSocketService.getInstance().navigationTargetStream.listen(
      (target) async {
        _log.info('Received Linux navigation target: $target');
        if (_linuxRadController == null) {
          _log.warning('Linux controller is null, skipping navigation.');
          return;
        }

        final Uri targetUri = Uri.tryParse(target) ?? Uri();
        final bool isFullUrl = targetUri.hasScheme &&
            (targetUri.scheme == 'http' || targetUri.scheme == 'https');

        if (isFullUrl) {
          // Handle navigate_url command (full URL)
          _log.info('Navigating Linux via navigateToUrl to: $target');
          _linuxRadController!.navigateToUrl(target);
        } else {
          // Handle navigate command (relative path)
          final String path = target.startsWith('/') ? target : '/$target';
          final String baseOrigin = Uri.parse(url).origin;
          String? currentWebViewUrlRaw;
          try {
            currentWebViewUrlRaw = await _linuxRadController!
                .evaluateJavascript('window.location.href');
          } catch (e, s) {
            _log.warning(
                'Error getting current Linux URL for JS nav check: $e', e, s);
          }

          String? currentWebViewUrl = currentWebViewUrlRaw?.trim();
          if (currentWebViewUrl != null &&
              currentWebViewUrl.startsWith('"') &&
              currentWebViewUrl.endsWith('"')) {
            currentWebViewUrl =
                currentWebViewUrl.substring(1, currentWebViewUrl.length - 1);
          }

          final String currentOrigin = currentWebViewUrl != null
              ? Uri.parse(currentWebViewUrl).origin
              : '';

          if (currentOrigin == baseOrigin) {
            // Use JS pushState for faster navigation within the same origin
            final escapedPath = path
                .replaceAll(r'\', r'\\')
                .replaceAll(r"'", r"\'")
                .replaceAll(r'"', r'\"');
            final String jsNavigate = '''
              console.log('Navigating Linux via JS pushState to: $escapedPath');
              history.pushState(null, "", "$escapedPath");
              window.dispatchEvent(new CustomEvent("location-changed"));
              null; // Explicitly return null
            ''';
            _log.info('Navigating Linux via JS pushState to: $path');
            try {
              _linuxRadController!.evaluateJavascript(jsNavigate);
              final newFullUrl = '$baseOrigin$path';
              _log.info(
                  'Reporting Linux JS navigation URL change: $newFullUrl');
              if (mounted && WebSocketService.getInstance().isConnected) {
                WebSocketService.getInstance().updateCurrentUrl(newFullUrl);
              } else {
                _log.warning(
                    "WebSocket disconnected or unmounted before Linux JS URL update could be sent.");
              }
            } catch (e, s) {
              _log.severe(
                  'Error running Linux JS navigation: $e. Falling back to navigateToUrl.',
                  e,
                  s);
              final fullUrl = '$baseOrigin$path';
              _linuxRadController!.navigateToUrl(fullUrl);
            }
          } else {
            // Fallback to full load if origins don't match or current URL is unknown
            final fullUrl = '$baseOrigin$path';
            _log.warning(
                'Linux origins mismatch or current URL unknown ($currentOrigin vs $baseOrigin). Navigating via navigateToUrl to: $fullUrl');
            _linuxRadController!.navigateToUrl(fullUrl);
          }
        }
      },
      onError: (error, stackTrace) {
        _log.severe(
            'Error on Linux navigation stream: $error', error, stackTrace);
      },
    );

    _isNavigatingListener = () async {
      if (!_linuxWebview!.isNavigating.value) {
        if (!_linuxTokenInjected) {
          _log.fine(
              "isNavigating is false and token not injected. Attempting token injection.");
          await _injectTokenLinux(authService);
        }

        if (_linuxTokenInjected && _linuxRadController != null) {
          _log.fine(
              "isNavigating is false, token injected. Injecting device ID...");
          final deviceId =
              Provider.of<AppStateProvider>(context, listen: false).deviceId;
          final deviceStorageKey =
              WebSocketService.getInstance().deviceStorageKey;
          if (deviceId != null) {
            final deviceIdJs = '''
              try {
                localStorage.setItem('$deviceStorageKey', '$deviceId');
                console.log('Set localStorage[$deviceStorageKey] = $deviceId (on page load)');
              } catch (e) {
                console.error('Error setting device ID in localStorage (on page load):', e);
              }
            ''';
            try {
              await _linuxRadController!.evaluateJavascript(deviceIdJs);
            } catch (e, s) {
              _log.severe(
                  "Error injecting device ID JS in isNavigatingListener: $e",
                  e,
                  s);
            }
          } else {
            _log.warning(
                "Cannot inject device ID in isNavigatingListener: deviceId is null.");
          }

          _log.fine("Getting current URL after device ID injection...");
          try {
            final currentUrlRaw = await _linuxRadController!
                .evaluateJavascript('window.location.href');

            String? currentUrl = currentUrlRaw?.trim();
            if (currentUrl != null &&
                currentUrl.startsWith('"') &&
                currentUrl.endsWith('"')) {
              currentUrl = currentUrl.substring(1, currentUrl.length - 1);
            }

            if (currentUrl != null && currentUrl.isNotEmpty) {
              _log.info(
                  "Current Linux URL (from isNavigating=false): $currentUrl");
              if (mounted && WebSocketService.getInstance().isConnected) {
                WebSocketService.getInstance().updateCurrentUrl(currentUrl);
              } else {
                _log.warning(
                    "WebSocket disconnected or unmounted before URL update (from isNavigating=false) could be sent.");
              }
            } else {
              _log.warning("evaluateJavascript returned null or empty URL.");
            }
          } catch (e, s) {
            _log.severe("Error getting URL via evaluateJavascript: $e", e, s);
          }
        } else {
          _log.warning(
              "isNavigating is false, but token not injected or controller null. Cannot get URL.");
        }
      } else {
        _log.fine("isNavigating is true (still loading).");
      }
    };
    _linuxWebview!.isNavigating.addListener(_isNavigatingListener!);

    _linuxWebview!
      ..onClose.whenComplete(() {
        _log.info("Linux WebView closed.");
        if (mounted) {
          if (_isNavigatingListener != null) {
            _linuxWebview?.isNavigating.removeListener(_isNavigatingListener!);
            _isNavigatingListener = null;
          }
          setState(() {
            _linuxWebview = null;
            _linuxInitialLoadAttempted = true;
            _linuxTokenInjected = false;
            _isWebViewReady = false;
            _isWebSocketConnecting = false;
            _lastInjectedAccessToken = null;
          });
        }
      });

    _linuxInitialLoadAttempted = true;
    _log.info("Launching Linux WebView with URL: $url");
    try {
      _linuxWebview!.launch(url);
    } catch (e, s) {
      _log.severe("Error launching URL in Linux WebView: $e", e, s);
      _closeLinuxWebview();
      return;
    }
  }

  void _signalWebViewReady() {
    if (!mounted) return;
    _log.info("WebView is ready (page loaded + token injected).");
    setState(() {
      _isWebViewReady = true;
    });
    _connectWebSocket();
  }

  void _connectWebSocket() {
    if (!mounted || !_isWebViewReady || _isWebSocketConnecting) {
      _log.fine(
          "Skipping WebSocket connect: mounted=$mounted, webViewReady=$_isWebViewReady, connecting=$_isWebSocketConnecting");
      return;
    }

    final appState = Provider.of<AppStateProvider>(context, listen: false);
    final authService = Provider.of<AuthService>(context, listen: false);
    final wsService = WebSocketService.getInstance();

    if (authService.state == AuthState.authenticated &&
        appState.homeAssistantUrl != null &&
        appState.deviceId != null) {
      if (!wsService.isConnected) {
        _log.info("Conditions met. Connecting WebSocket...");
        setState(() {
          _isWebSocketConnecting = true;
        });
        Future.microtask(() async {
          try {
            await wsService.connect(
              appState.homeAssistantUrl!,
              authService,
              appState.deviceId!,
            );
            if (mounted) {
              setState(() {
                _isWebSocketConnecting = false;
              });
            }
          } catch (e, s) {
            _log.severe("WebSocket connection failed: $e", e, s);
            if (mounted) {
              setState(() {
                _isWebSocketConnecting = false;
              });
            }
          }
        });
      } else {
        _log.fine("WebSocket already connected.");
      }
    } else {
      _log.warning(
          "Cannot connect WebSocket: Not authenticated, URL missing, or DeviceID missing.");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<AppStateProvider, AuthService>(
      builder: (context, appState, authService, _) {
        _log.fine("Rebuilding UI. Auth State: ${authService.state}");

        if (authService.state != AuthState.authenticated) {
          _log.info("Not authenticated, showing AuthScreen.");
          if (_linuxWebview != null) {
            _closeLinuxWebview();
          }
          return const AuthScreen();
        }

        final homeAssistantUrl = appState.homeAssistantUrl;

        if (homeAssistantUrl == null) {
          _log.warning(
              "Authenticated but URL is null. Showing loading indicator.");
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        _log.info("Authenticated. Target URL: $homeAssistantUrl");

        if (Platform.isAndroid) {
          _log.info("Platform is Android. Showing AndroidWebViewWidget.");

          final tokens = authService.tokens;
          final accessToken = tokens?['access_token'] as String?;
          final refreshToken = tokens?['refresh_token'] as String?;
          final expiresIn = tokens?['expires_in'] as int?;

          // The GestureDetector is removed as the logic is now inside AndroidWebViewWidget
          return AndroidWebViewWidget(
            key: ValueKey(
                homeAssistantUrl), // Keep key if needed for state reset on URL change
            initialUrl: homeAssistantUrl,
            onPageFinished: (url) {
              _log.info("AndroidWebViewWidget finished loading: $url");
              // Signal ready state if not already done (e.g., if initial load)
              // The gesture detector is now part of AndroidWebViewWidget itself.
              // We might still need to signal readiness for WebSocket connection here.
              if (!_isWebViewReady) {
                _signalWebViewReady();
              }
            },
          ); // End of AndroidWebViewWidget
        } else if (Platform.isLinux) {
          _log.info("Platform is Linux.");

          final currentAccessToken =
              authService.tokens?['access_token'] as String?;
          if (_linuxWebview != null &&
              currentAccessToken != null &&
              currentAccessToken != _lastInjectedAccessToken) {
            _log.info(
                "Detected token change. Re-injecting token into Linux webview.");
            Future.microtask(() => _injectTokenLinux(authService));
          }

          if (_linuxWebview == null && !_linuxInitialLoadAttempted) {
            _log.info("Linux WebView is null and not attempted, creating...");
            Future.microtask(() =>
                _createAndLaunchLinuxWebview(homeAssistantUrl, authService));
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          } else if (_linuxWebview == null && _linuxInitialLoadAttempted) {
            _log.warning(
                "Linux WebView creation previously attempted but failed or closed.");
            return const AuthScreen();
          }

          _log.info(
              "Linux WebView active or initializing. Showing placeholder UI.");
          return Scaffold(
            appBar: AppBar(
              title: const Text('Remote Assist Display'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.logout),
                  tooltip: 'Logout',
                  onPressed: () {
                    _log.info("Logout button pressed.");
                    _closeLinuxWebview();
                    authService.logout();
                  },
                ),
              ],
            ),
            body: const SettingsScreen(),
          );
        } else {
          _log.severe("Unsupported platform.");
          return Scaffold(
            body: Center(
                child:
                    Text("Unsupported Platform: ${Platform.operatingSystem}")),
          );
        }
      },
    );
  }
}
