import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart'; // Import ValueListenable
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart';

import '../providers/app_state_provider.dart';
import '../services/auth_service.dart';
import '../oauth_config.dart';
import '../webview_controller.dart';
import '../widgets/android_webview_widget.dart';
import 'auth_screen.dart';

class RadApp extends StatefulWidget {
  const RadApp({super.key});

  @override
  State<RadApp> createState() => _RadAppState();
}

class _RadAppState extends State<RadApp> {
  Webview? _linuxWebview;
  LinuxWebViewController? _linuxRadController;
  bool _linuxInitialLoadAttempted = false;
  bool _linuxTokenInjected = false;
  VoidCallback? _isNavigatingListener;

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

    _isNavigatingListener = () {
      if (!_linuxWebview!.isNavigating.value && !_linuxTokenInjected) {
        print("[AppShell] isNavigating is false. Attempting token injection.");
        Future.microtask(() => _injectTokenLinux(authService));
      } else if (_linuxWebview!.isNavigating.value) {
        print("[AppShell] isNavigating is true.");
      } else if (_linuxTokenInjected) {
        print("[AppShell] isNavigating is false, but token already injected.");
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

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Remote Assist Display CXP',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: Consumer2<AppStateProvider, AuthService>(
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
            print("[AppShell] Authenticated but URL is null. Logging out.");
            Future.microtask(() => authService.logout());
            return const Scaffold(
              body: Center(
                  child:
                      Text("Error: Missing Home Assistant URL. Logging out.")),
            );
          }

          print("[AppShell] Authenticated. Target URL: $homeAssistantUrl");

          if (Platform.isAndroid) {
            print(
                "[AppShell] Platform is Android. Showing AndroidWebViewWidget.");

            // Extract token details for AndroidWebViewWidget
            final tokens = authService.tokens;
            final accessToken = tokens?['access_token'] as String?;
            final refreshToken = tokens?['refresh_token'] as String?;
            final expiresIn = tokens?['expires_in'] as int?;

            return AndroidWebViewWidget(
              url: homeAssistantUrl,
              accessToken: accessToken,
              refreshToken: refreshToken,
              expiresIn: expiresIn,
              onSuccess: () {
                print("[AppShell] AndroidWebViewWidget reported success.");
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
            // Unsupported platform
            print("[AppShell] Unsupported platform.");
            return Scaffold(
              body: Center(
                  child: Text(
                      "Unsupported Platform: ${Platform.operatingSystem}")),
            );
          }
        },
      ),
    );
  }
}
