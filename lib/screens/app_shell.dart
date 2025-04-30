import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart';

import '../providers/app_state_provider.dart';
import '../services/auth_service.dart';
import '../services/websocket_service.dart';
import '../oauth_config.dart';
import '../webview_controller.dart';
import '../widgets/android_webview_widget.dart';
import 'auth_screen.dart';

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
        print("[AppShell] Closing Linux WebView");
        if (_isNavigatingListener != null) {
          _linuxWebview?.isNavigating.removeListener(_isNavigatingListener!);
          _isNavigatingListener = null;
        }
        _navigationSubscription?.cancel();
        _navigationSubscription = null;
        _linuxWebview?.close();
      }
    } catch (e) {
      print(
          "[AppShell] Error closing Linux Webview (might be already closed): $e");
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
      print(
          "[AppShell] Cannot inject token: Linux webview or controller not ready.");
      return;
    }
    final tokens = authService.tokens;
    final hassUrl = authService.hassUrl;

    if (tokens != null && hassUrl != null) {
      final accessToken = tokens['access_token'] as String?;
      final refreshToken = tokens['refresh_token'] as String?;
      final expiresIn = tokens['expires_in'] as int?;
      final clientId = OAuthConfig.buildClientId(hassUrl);

      if (accessToken != null && refreshToken != null && expiresIn != null) {
        print(
            "[AppShell] Injecting token into Linux WebView via evaluateJavascript...");
        try {
          final js = AuthService.generateTokenInjectionJs(
            accessToken,
            refreshToken,
            expiresIn,
            clientId,
            hassUrl,
          );
          await _linuxRadController!.evaluateJavascript(js);
          _linuxTokenInjected = true;
          _lastInjectedAccessToken = accessToken;
          print(
              "[AppShell] Linux token injected/updated successfully via evaluateJavascript.");
          if (!_isWebViewReady) {
            _signalWebViewReady();
          }
        } catch (e) {
          print("[AppShell] Error injecting token into Linux WebView: $e");
        }
      } else {
        print("[AppShell] Cannot inject token: Missing token details.");
        authService.logout();
      }
    } else {
      print("[AppShell] Cannot inject token: No token or hassUrl available.");
      authService.logout();
    }
  }

  Future<void> _createAndLaunchLinuxWebview(
      String url, AuthService authService) async {
    if (_linuxWebview != null) {
      print("[AppShell] Linux WebView already exists. Closing and recreating.");
      _closeLinuxWebview();
    }

    _linuxInitialLoadAttempted = false;
    _linuxTokenInjected = false;
    _isWebViewReady = false;
    _isWebSocketConnecting = false;
    _lastInjectedAccessToken = null;

    print("[AppShell] Creating Linux WebView window...");
    try {
      _linuxWebview = await WebviewWindow.create(
        configuration: CreateConfiguration(
          openFullscreen: true,
          forceNativeChromeless: true,
        ),
      );
    } catch (e) {
      print("[AppShell] Error creating Linux WebView: $e");
      return;
    }

    print("[AppShell] Linux WebView created. Setting up callbacks.");
    _linuxRadController = LinuxWebViewController();
    _linuxRadController!.setLinuxWebview(_linuxWebview!);

    _navigationSubscription?.cancel();
    _navigationSubscription =
        WebSocketService.getInstance().navigationTargetStream.listen(
      (target) async {
        print('[AppShell] Received Linux navigation target: $target');
        if (_linuxRadController == null) {
          print('[AppShell] Linux controller is null, skipping navigation.');
          return;
        }

        final Uri targetUri = Uri.tryParse(target) ?? Uri();
        final bool isFullUrl = targetUri.hasScheme &&
            (targetUri.scheme == 'http' || targetUri.scheme == 'https');

        if (isFullUrl) {
          // Handle navigate_url command (full URL)
          print('[AppShell] Navigating Linux via navigateToUrl to: $target');
          _linuxRadController!.navigateToUrl(target);
          // URL update will be handled by the isNavigating listener
        } else {
          // Handle navigate command (relative path)
          final String path = target.startsWith('/') ? target : '/$target';
          final String baseOrigin = Uri.parse(url).origin;
          String? currentWebViewUrlRaw;
          try {
            currentWebViewUrlRaw = await _linuxRadController!
                .evaluateJavascript('window.location.href');
          } catch (e) {
            print(
                '[AppShell] Error getting current Linux URL for JS nav check: $e');
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
            print('[AppShell] Navigating Linux via JS pushState to: $path');
            try {
              _linuxRadController!.evaluateJavascript(jsNavigate);
              final newFullUrl = '$baseOrigin$path';
              print(
                  '[AppShell] Reporting Linux JS navigation URL change: $newFullUrl');
              if (mounted && WebSocketService.getInstance().isConnected) {
                WebSocketService.getInstance().updateCurrentUrl(newFullUrl);
              } else {
                print(
                    "[AppShell] WebSocket disconnected or unmounted before Linux JS URL update could be sent.");
              }
            } catch (e) {
              print(
                  '[AppShell] Error running Linux JS navigation: $e. Falling back to navigateToUrl.');
              final fullUrl = '$baseOrigin$path';
              _linuxRadController!.navigateToUrl(fullUrl);
            }
          } else {
            // Fallback to full load if origins don't match or current URL is unknown
            final fullUrl = '$baseOrigin$path';
            print(
                '[AppShell] Linux origins mismatch or current URL unknown ($currentOrigin vs $baseOrigin). Navigating via navigateToUrl to: $fullUrl');
            _linuxRadController!.navigateToUrl(fullUrl);
          }
        }
      },
      onError: (error) {
        print('[AppShell] Error on Linux navigation stream: $error');
      },
    );

    _isNavigatingListener = () async {
      if (!_linuxWebview!.isNavigating.value) {
        if (!_linuxTokenInjected) {
          print(
              "[AppShell] isNavigating is false and token not injected. Attempting token injection.");
          await _injectTokenLinux(authService);
        }
        if (_linuxTokenInjected && _linuxRadController != null) {
          print(
              "[AppShell] isNavigating is false, token injected. Getting current URL...");
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
              print(
                  "[AppShell] Current Linux URL (from isNavigating=false): $currentUrl");
              if (mounted && WebSocketService.getInstance().isConnected) {
                WebSocketService.getInstance().updateCurrentUrl(currentUrl);
              } else {
                print(
                    "[AppShell] WebSocket disconnected or unmounted before URL update (from isNavigating=false) could be sent.");
              }
            } else {
              print(
                  "[AppShell] evaluateJavascript returned null or empty URL.");
            }
          } catch (e) {
            print("[AppShell] Error getting URL via evaluateJavascript: $e");
          }
        } else {
          print(
              "[AppShell] isNavigating is false, but token not injected or controller null. Cannot get URL.");
        }
      } else {
        print("[AppShell] isNavigating is true (still loading).");
      }
    };
    _linuxWebview!.isNavigating.addListener(_isNavigatingListener!);

    _linuxWebview!
      ..onClose.whenComplete(() {
        print("[AppShell] Linux WebView closed.");
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
    print("[AppShell] Launching Linux WebView with URL: $url");
    try {
      _linuxWebview!.launch(url);
    } catch (e) {
      print("[AppShell] Error launching URL in Linux WebView: $e");
      _closeLinuxWebview();
      return;
    }
  }

  void _signalWebViewReady() {
    if (!mounted) return;
    print("[AppShell] WebView is ready (page loaded + token injected).");
    setState(() {
      _isWebViewReady = true;
    });
    _connectWebSocket();
  }

  void _connectWebSocket() {
    if (!mounted || !_isWebViewReady || _isWebSocketConnecting) {
      print(
          "[AppShell] Skipping WebSocket connect: mounted=$mounted, webViewReady=$_isWebViewReady, connecting=$_isWebSocketConnecting");
      return;
    }

    final appState = Provider.of<AppStateProvider>(context, listen: false);
    final authService = Provider.of<AuthService>(context, listen: false);
    final wsService = WebSocketService.getInstance();

    if (authService.state == AuthState.authenticated &&
        appState.homeAssistantUrl != null &&
        appState.deviceId != null) {
      if (!wsService.isConnected) {
        print("[AppShell] Conditions met. Connecting WebSocket...");
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
          } catch (e) {
            print("[AppShell] WebSocket connection failed: $e");
            if (mounted) {
              setState(() {
                _isWebSocketConnecting = false;
              });
            }
          }
        });
      } else {
        print("[AppShell] WebSocket already connected.");
      }
    } else {
      print(
          "[AppShell] Cannot connect WebSocket: Not authenticated, URL missing, or DeviceID missing.");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<AppStateProvider, AuthService>(
      builder: (context, appState, authService, _) {
        print("[AppShell] Rebuilding UI. Auth State: ${authService.state}");

        if (authService.state != AuthState.authenticated) {
          print("[AppShell] Not authenticated, showing AuthScreen.");
          if (_linuxWebview != null) {
            _closeLinuxWebview();
          }
          return const AuthScreen();
        }

        final homeAssistantUrl = appState.homeAssistantUrl;

        if (homeAssistantUrl == null) {
          print(
              "[AppShell] Authenticated but URL is null. Showing loading indicator.");
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        print("[AppShell] Authenticated. Target URL: $homeAssistantUrl");

        if (Platform.isAndroid) {
          print(
              "[AppShell] Platform is Android. Showing AndroidWebViewWidget.");

          final tokens = authService.tokens;
          final accessToken = tokens?['access_token'] as String?;
          final refreshToken = tokens?['refresh_token'] as String?;
          final expiresIn = tokens?['expires_in'] as int?;

          return AndroidWebViewWidget(
            url: homeAssistantUrl,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresIn: expiresIn,
            onWebViewReady: _signalWebViewReady,
            onSuccess: () {
              print(
                  "[AppShell] AndroidWebViewWidget reported initial load success.");
            },
            onError: (error) {
              print("[AppShell] AndroidWebViewWidget reported error: $error");
            },
          );
        } else if (Platform.isLinux) {
          print("[AppShell] Platform is Linux.");

          final currentAccessToken =
              authService.tokens?['access_token'] as String?;
          if (_linuxWebview != null &&
              currentAccessToken != null &&
              currentAccessToken != _lastInjectedAccessToken) {
            print(
                "[AppShell] Detected token change. Re-injecting token into Linux webview.");
            Future.microtask(() => _injectTokenLinux(authService));
          }

          if (_linuxWebview == null && !_linuxInitialLoadAttempted) {
            print(
                "[AppShell] Linux WebView is null and not attempted, creating...");
            Future.microtask(() =>
                _createAndLaunchLinuxWebview(homeAssistantUrl, authService));
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          } else if (_linuxWebview == null && _linuxInitialLoadAttempted) {
            print(
                "[AppShell] Linux WebView creation previously attempted but failed or closed.");
            return const AuthScreen();
          }

          print(
              "[AppShell] Linux WebView active or initializing. Showing placeholder UI.");
          return Scaffold(
            appBar: AppBar(
              title: const Text('Remote Assist Display'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.logout),
                  tooltip: 'Logout',
                  onPressed: () {
                    print("[AppShell] Logout button pressed.");
                    _closeLinuxWebview();
                    authService.logout();
                  },
                ),
              ],
            ),
            body: const Center(
              child: Padding(
                padding: EdgeInsets.all(16.0),
                child: Text(
                  'Home Assistant display is active in a separate window.',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        } else {
          print("[AppShell] Unsupported platform.");
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
