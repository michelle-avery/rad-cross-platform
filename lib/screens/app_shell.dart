import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:logging/logging.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

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

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  // Add WidgetsBindingObserver mixin
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
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<AuthService>(context, listen: false).loadTokens();
      if (Platform.isAndroid &&
          Provider.of<AuthService>(context, listen: false).state ==
              AuthState.authenticated) {
        _log.info("Enabling wakelock on initial load (Android).");
        WakelockPlus.enable();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (!Platform.isAndroid) return;

    try {
      final isAuthenticated =
          Provider.of<AuthService>(context, listen: false).state ==
              AuthState.authenticated;

      if (isAuthenticated) {
        switch (state) {
          case AppLifecycleState.resumed:
            _log.info("App resumed, enabling wakelock (Android).");
            WakelockPlus.enable();
            break;
          case AppLifecycleState.inactive:
          case AppLifecycleState.paused:
          case AppLifecycleState.detached:
          case AppLifecycleState.hidden:
            _log.info(
                "App inactive/paused/detached/hidden, disabling wakelock (Android).");
            WakelockPlus.disable();
            break;
        }
      } else {
        _log.info(
            "App lifecycle changed but not authenticated, ensuring wakelock is disabled (Android).");
        WakelockPlus.disable();
      }
    } catch (e, s) {
      _log.warning(
          "Error accessing provider during lifecycle change, ensuring wakelock is disabled: $e",
          e,
          s);
      WakelockPlus.disable();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isAndroid) {
      _log.info("Disposing widget, disabling wakelock (Android).");
      WakelockPlus.disable();
    }
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

    if (tokens != null && hassUrl != null) {
      final accessToken = tokens['access_token'] as String?;
      final refreshToken = tokens['refresh_token'] as String?;
      final expiresIn = tokens['expires_in'] as int?;
      final clientId = OAuthConfig.buildClientId(hassUrl);

      if (accessToken != null && refreshToken != null && expiresIn != null) {
        _log.info(
            "Injecting token into Linux WebView via RadWebViewController helper...");
        try {
          final authJs = RadWebViewController.generateAuthInjectionJs(
            accessToken,
            refreshToken,
            expiresIn,
            clientId,
            hassUrl,
          );
          await _linuxRadController!.evaluateJavascript(authJs);

          final appState =
              Provider.of<AppStateProvider>(context, listen: false);
          final deviceId = appState.deviceId;
          final deviceStorageKey =
              WebSocketService.getInstance().deviceStorageKey;
          if (deviceId != null) {
            final displaySettingsJs =
                RadWebViewController.generateDisplaySettingsInjectionJs(
              deviceId,
              deviceStorageKey,
              appState.hideHeader,
              appState.hideSidebar,
            );
            await _linuxRadController!.evaluateJavascript(displaySettingsJs);
          } else {
            _log.warning(
                "Cannot inject device ID during auth injection: deviceId is null.");
          }

          _linuxTokenInjected = true;
          _lastInjectedAccessToken = accessToken;
          _log.info(
              "Linux token and device ID injected/updated successfully via helper.");
          if (!_isWebViewReady) {
            _signalWebViewReady();
          }
        } catch (e, s) {
          _log.severe(
              "Error injecting token/device ID into Linux WebView: $e", e, s);
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
        final String baseOrigin = Uri.parse(url).origin;

        await RadWebViewController.handleNavigation(
          controller: _linuxRadController!,
          target: target,
          currentBaseOrigin: baseOrigin,
          refreshSignal: refreshSignal,
        );
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
              "isNavigating is false, token injected. Injecting display settings...");
          final appState =
              Provider.of<AppStateProvider>(context, listen: false);
          final deviceId = appState.deviceId;
          final deviceStorageKey =
              WebSocketService.getInstance().deviceStorageKey;
          if (deviceId != null) {
            final displaySettingsJs =
                RadWebViewController.generateDisplaySettingsInjectionJs(
              deviceId,
              deviceStorageKey,
              appState.hideHeader,
              appState.hideSidebar,
            );
            try {
              await _linuxRadController!.evaluateJavascript(displaySettingsJs);
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
            final currentUrl = await _linuxRadController!.getCurrentUrl();

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
              _log.warning("getCurrentUrl returned null or empty URL.");
            }
          } catch (e, s) {
            _log.severe("Error getting URL via getCurrentUrl: $e", e, s);
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
    final initialUrlWithCallback = Uri.parse(url).replace(
      queryParameters: {'auth_callback': '1'},
    ).toString();
    _log.info("Launching Linux WebView with URL: $initialUrlWithCallback");
    try {
      _linuxWebview!.launch(initialUrlWithCallback);
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
              appState,
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

          final initialUrlWithCallback = Uri.parse(homeAssistantUrl).replace(
            queryParameters: {'auth_callback': '1'},
          ).toString();
          _log.info(
              "Initial Android URL with auth_callback: $initialUrlWithCallback");

          return AndroidWebViewWidget(
            key: ValueKey(homeAssistantUrl),
            initialUrl: initialUrlWithCallback,
            onPageFinished: (url) {
              _log.info("AndroidWebViewWidget finished loading: $url");
              if (!_isWebViewReady) {
                _signalWebViewReady();
              }
            },
          );
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
