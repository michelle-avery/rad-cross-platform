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
    }
  }

  Future<void> _injectTokenLinux(AuthService authService) async {
    if (_linuxWebview == null ||
        _linuxRadController == null ||
        _linuxTokenInjected) {
      print(
          "[AppShell] Cannot inject token: Linux webview not ready or token already injected.");
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
          print(
              "[AppShell] Linux token injected successfully via evaluateJavascript.");
          _signalWebViewReady();
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
      (dashboardPath) {
        print('[AppShell] Received Linux navigation target: $dashboardPath');
        String baseUrl =
            url.endsWith('/') ? url.substring(0, url.length - 1) : url;
        String path =
            dashboardPath.startsWith('/') ? dashboardPath : '/$dashboardPath';
        final fullUrl = '$baseUrl$path';

        print('[AppShell] Navigating Linux WebView to: $fullUrl');
        _linuxRadController?.navigateToUrl(fullUrl);
        Future.delayed(const Duration(milliseconds: 1000), () async {
          if (mounted && _linuxRadController != null) {
            try {
              final navigatedUrl = await _linuxRadController!
                  .evaluateJavascript('window.location.href');
              if (navigatedUrl != null && navigatedUrl.isNotEmpty) {
                print(
                    "[AppShell] Current Linux URL (after commanded nav): $navigatedUrl");
                if (WebSocketService.getInstance().isConnected) {
                  WebSocketService.getInstance().updateCurrentUrl(navigatedUrl);
                } else {
                  print(
                      "[AppShell] WebSocket disconnected before URL update (after commanded nav) could be sent.");
                }
              }
            } catch (e) {
              print(
                  "[AppShell] Error getting URL after commanded navigation: $e");
            }
          }
        });
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
            final currentUrl = await _linuxRadController!
                .evaluateJavascript('window.location.href');
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
              "[AppShell] Linux WebView active (or attempting). Showing placeholder UI.");
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
