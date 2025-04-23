import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'dart:io';
import 'package:provider/provider.dart';
import 'app_state_provider.dart';
import 'android_webview_widget.dart';
import 'auth_service.dart';
import 'oauth_webview.dart';
import 'package:webview_flutter/webview_flutter.dart' as android_webview;
import 'webview_controller.dart';
import 'package:flutter/foundation.dart';

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    if (runWebViewTitleBarWidget(args)) {
      return;
    }
  }
  final authService = AuthService();
  await authService.loadTokens();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppStateProvider()),
        ChangeNotifierProvider<AuthService>.value(value: authService),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  android_webview.WebViewController? _androidWebViewController;

  Webview? _linuxWebview;
  LinuxWebViewController? _linuxRadController;
  bool _linuxTokenInjected = false;
  bool _linuxWebviewInitializing = false;
  ValueListenable<bool>? _isNavigatingNotifier;
  VoidCallback? _navigationListener;

  @override
  void dispose() {
    if (_navigationListener != null && _isNavigatingNotifier != null) {
      _isNavigatingNotifier!.removeListener(_navigationListener!);
    }
    _linuxWebview?.close();
    super.dispose();
  }

  Future<void> _initializeAndLaunchLinuxWebview(
      String url, AuthService authService) async {
    if (_linuxWebview != null || _linuxWebviewInitializing) return;
    setState(() {
      _linuxWebviewInitializing = true;
    });

    try {
      _linuxWebview = await WebviewWindow.create(
        configuration: CreateConfiguration(
          openFullscreen: true,
          forceNativeChromeless: true,
        ),
      );
    } catch (e) {
      print('[MyApp Linux] Error creating webview: $e');
      setState(() {
        _linuxWebviewInitializing = false;
      });
      return;
    }

    _linuxRadController = LinuxWebViewController();
    _linuxRadController!.setLinuxWebview(_linuxWebview!);

    _linuxTokenInjected = false;

    if (_navigationListener != null && _isNavigatingNotifier != null) {
      _isNavigatingNotifier!.removeListener(_navigationListener!);
    }

    _isNavigatingNotifier = _linuxWebview!.isNavigating;
    _navigationListener = () async {
      if (_isNavigatingNotifier?.value == false &&
          !_linuxTokenInjected &&
          authService.tokens != null &&
          authService.hassUrl != null) {
        final tokens = authService.tokens!;
        final js = AuthService.generateTokenInjectionJs(
          tokens['access_token'],
          tokens['refresh_token'],
          tokens['expires_in'],
          authService.hassUrl!,
          authService.hassUrl!,
        );
        try {
          await _linuxRadController!.evaluateJavascript(js);
          setState(() {
            _linuxTokenInjected = true;
          });
        } catch (e) {
          print('[MyApp Linux] Error injecting JS: $e');
        }
      }
    };
    _isNavigatingNotifier!.addListener(_navigationListener!);

    _linuxWebview!.onClose.whenComplete(() {
      if (_navigationListener != null && _isNavigatingNotifier != null) {
        _isNavigatingNotifier!.removeListener(_navigationListener!);
      }
      setState(() {
        _linuxWebview = null;
        _linuxRadController = null;
        _linuxTokenInjected = false;
        _linuxWebviewInitializing = false;
        _navigationListener = null;
        _isNavigatingNotifier = null;
      });
    });

    _linuxRadController!.navigateToUrl(url);
    setState(() {
      _linuxWebviewInitializing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Remote Assist Display CXP',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: Consumer2<AppStateProvider, AuthService>(
        builder: (context, appState, authService, _) {
          if (authService.state != AuthState.authenticated) {
            if (_linuxWebview != null) {
              _linuxWebview?.close();
              _linuxWebview = null;
              _linuxRadController = null;
            }
            return const AuthScreen();
          }

          if (appState.homeAssistantUrl == null) {
            return Scaffold(
                body: Center(child: Text('Error: Missing Home Assistant URL')));
          }

          if (Platform.isAndroid) {
            _androidWebViewController ??= android_webview.WebViewController();

            return Scaffold(
              body: SafeArea(
                child: AndroidWebViewWidget(
                  url: appState.homeAssistantUrl!,
                  controller: _androidWebViewController,
                  accessToken: authService.tokens?['access_token'],
                  refreshToken: authService.tokens?['refresh_token'],
                  expiresIn: authService.tokens?['expires_in'],
                ),
              ),
            );
          } else if (Platform.isLinux) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _initializeAndLaunchLinuxWebview(
                  appState.homeAssistantUrl!, authService);
            });

            return Scaffold(
              appBar: AppBar(title: Text('RAD Connected')),
              body: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_linuxWebviewInitializing) CircularProgressIndicator(),
                    if (_linuxWebview != null && !_linuxWebviewInitializing)
                      Text('Home Assistant dashboard is in a separate window.'),
                    if (_linuxWebview == null && !_linuxWebviewInitializing)
                      Text('Launching Home Assistant...'),
                    SizedBox(height: 20),
                    ElevatedButton(
                        onPressed: () => authService.logout(),
                        child: Text('Logout'))
                  ],
                ),
              ),
            );
          } else {
            return Scaffold(
                body: Center(child: Text('Platform not supported')));
          }
        },
      ),
    );
  }
}

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _urlController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;
  Webview? _linuxAuthWebview;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _closeLinuxAuthWebview();
    super.dispose();
  }

  void _closeLinuxAuthWebview() {
    try {
      if (_linuxAuthWebview != null) {
        _linuxAuthWebview?.close();
      }
    } catch (e) {
      print(
          '[AuthScreen] Error closing Linux Auth Webview (might be already closed): $e'); // Keep error print
    } finally {
      _linuxAuthWebview = null;
    }
  }

  Future<void> _login() async {
    if (_urlController.text.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter your Home Assistant URL';
      });
      return;
    }

    FocusScope.of(context).unfocus();

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final authService = Provider.of<AuthService>(context, listen: false);
    final appState = Provider.of<AppStateProvider>(context, listen: false);

    try {
      final validatedUrl =
          await authService.validateAndSetUrl(_urlController.text);
      await appState.setHomeAssistantUrl(validatedUrl);
      final authUrl = authService.getAuthorizationUrl();

      if (Platform.isAndroid) {
        void handleAndroidAuthCode(String code, String state) async {
          try {
            await authService.handleAuthCode(code, state);
          } catch (e) {
            print('[AuthScreen] Error handling auth code from Android: $e');
            if (mounted) {
              setState(() {
                _errorMessage = 'Authentication failed: ${e.toString()}';
                _isLoading = false;
              });
            }
          }
        }

        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => OAuthWebView(
              authUrl: authUrl,
              onAuthCode: handleAndroidAuthCode,
            ),
          ),
        );
        if (mounted && authService.state != AuthState.authenticated) {
          setState(() {
            if (_errorMessage == null) {
              _errorMessage = 'Authentication cancelled or failed.';
            }
            _isLoading = false;
          });
        }
      } else if (Platform.isLinux) {
        await _startLinuxAuthFlow(authUrl, authService, validatedUrl);
      } else {
        throw UnsupportedError('Platform not supported for login flow');
      }
    } catch (e) {
      print('[AuthScreen] Login Error: $e');
      if (mounted) {
        setState(() {
          _errorMessage = 'Login failed: ${e.toString()}';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _startLinuxAuthFlow(
      String authUrl, AuthService authService, String validatedUrl) async {
    _closeLinuxAuthWebview();

    try {
      _linuxAuthWebview = await WebviewWindow.create(
        configuration: CreateConfiguration(
          windowHeight: 700,
          windowWidth: 600,
          title: "Home Assistant Login",
        ),
      );
    } catch (e) {
      print('[AuthScreen Linux] Error creating auth webview: $e');
      if (mounted) {
        setState(() {
          _errorMessage = 'Could not open login window: $e';
          _isLoading = false;
        });
      }
      return;
    }

    bool codeHandled = false;

    void cleanup() {
      try {
        _linuxAuthWebview?.setOnUrlRequestCallback(null);
      } catch (e) {
        print('[AuthScreen Linux] Error removing URL request callback: $e');
      }
      _closeLinuxAuthWebview();
      if (!codeHandled && mounted && _isLoading) {
        setState(() {
          _isLoading = false;
        });
      }
    }

    final redirectUri = authService.redirectUri;

    _linuxAuthWebview!.setOnUrlRequestCallback((url) {
      if (url.startsWith(redirectUri) && !codeHandled) {
        codeHandled = true;
        Future.microtask(() async {
          try {
            final uri = Uri.parse(url);
            final code = uri.queryParameters['code'];
            final state = uri.queryParameters['state'];

            if (code != null && state != null) {
              await authService.handleAuthCode(code, state);
            } else {
              throw Exception('Missing code or state in redirect URI');
            }
          } catch (e) {
            print('[AuthScreen Linux] Error handling redirect: $e');
            if (mounted) {
              setState(() {
                _errorMessage = 'Authentication failed: ${e.toString()}';
              });
            }
          } finally {
            cleanup();
          }
        });
        return false;
      }
      return true;
    });

    _linuxAuthWebview!.onClose.whenComplete(() {
      if (!codeHandled && mounted) {
        setState(() {
          _errorMessage = 'Authentication cancelled.';
        });
      }
      cleanup();
    });

    try {
      _linuxAuthWebview!.launch(authUrl);
    } catch (e) {
      print('[AuthScreen Linux] Error launching URL in auth webview: $e');
      if (mounted) {
        setState(() {
          _errorMessage = 'Could not load login page: $e';
        });
      }
      cleanup();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_urlController.text.isEmpty) {
      final initialUrl = Provider.of<AppStateProvider>(context, listen: false)
          .homeAssistantUrl;
      if (initialUrl != null) {
        _urlController.text = initialUrl;
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Log In to Home Assistant'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _urlController,
                  decoration: InputDecoration(
                    labelText: 'Home Assistant URL',
                    hintText: 'e.g., http://homeassistantassistant.local:8123',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8.0),
                    ),
                  ),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                ),
                const SizedBox(height: 24),
                if (_isLoading)
                  const Center(child: CircularProgressIndicator())
                else
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16.0),
                      textStyle: const TextStyle(fontSize: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8.0),
                      ),
                    ),
                    onPressed: _login,
                    child: const Text('Connect'),
                  ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 20),
                  Text(
                    _errorMessage!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 14,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
