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
import 'package:webview_flutter/webview_flutter.dart';
import 'webview_controller.dart';

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
  WebViewController? _dashboardWebViewController;
  bool _tokenInjected = false;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Remote Assist Display CXP',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: Consumer2<AppStateProvider, AuthService>(
        builder: (context, appState, authService, _) {
          if (authService.state == AuthState.authenticated &&
              appState.isConfigured) {
            if (Platform.isAndroid) {
              if (!_tokenInjected) {
                final accessToken = authService.tokens?['access_token'];
                if (accessToken != null) {
                  _dashboardWebViewController = WebViewController();
                  final radController = createWebViewController(
                      androidController: _dashboardWebViewController!);
                  final js = '''
                    localStorage.setItem("hassTokens", JSON.stringify({
                      access_token: "$accessToken",
                      expires_in: 1800,
                      token_type: "Bearer"
                    }));
                    window.location.replace('/lovelace/0');
                  ''';
                  radController.evaluateJavascript(js);
                  _tokenInjected = true;
                }
              }
              return Scaffold(
                body: SafeArea(
                  child: AndroidWebViewWidget(
                    url: appState.homeAssistantUrl!,
                    controller: _dashboardWebViewController,
                    accessToken: authService.tokens?['access_token'],
                    refreshToken: authService.tokens?['refresh_token'],
                    expiresIn: authService.tokens?['expires_in'],
                  ),
                ),
              );
            } else if (Platform.isLinux) {
              return Scaffold(
                body: Center(child: Text('Webview is in a separate window.')),
              );
            }
          }
          // If not authenticated, show AuthScreen
          return const AuthScreen();
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

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  void _startOAuthFlow(BuildContext context) async {
    final authService = Provider.of<AuthService>(context, listen: false);
    final url = _urlController.text.trim();
    setState(() => _isLoading = true);
    final authUrl = await authService.startAuth(url);
    setState(() => _isLoading = false);
    // Show the in-app OAuth webview
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OAuthWebView(
          authUrl: authUrl,
          onAuthCode: (code, state) {
            authService.handleAuthCode(code, state);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final authService = Provider.of<AuthService>(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Login to Home Assistant')),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: 'Home Assistant URL',
                hintText: 'https://your-ha.local:8123',
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _isLoading ? null : () => _startOAuthFlow(context),
              child: _isLoading
                  ? const CircularProgressIndicator()
                  : const Text('Login'),
            ),
            const SizedBox(height: 24),
            if (authService.state == AuthState.error)
              Text(authService.errorMessage ?? 'Unknown error',
                  style: const TextStyle(color: Colors.red)),
          ],
        ),
      ),
    );
  }
}

class MyHomePage extends StatefulWidget {
  final String title;
  const MyHomePage({super.key, required this.title});
  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final TextEditingController _urlController = TextEditingController();
  bool _webviewLaunched = false;
  bool _pendingAndroidValidation = false;
  bool _loadFailed = false;
  bool _linuxLoadFailed = false;
  String? _pendingUrl;
  String? _errorText;
  String? _lastError;
  String? _linuxLastError;

  Future<bool> _validateUrl(String url) async {
    // For Android, we'll check if the WebView can load the page (handled in widget)
    // For Linux, do a simple HTTP GET to check reachability
    if (Platform.isLinux) {
      try {
        final uri = Uri.parse(url);
        final client = HttpClient();
        final request = await client.getUrl(uri);
        final response = await request.close();
        return response.statusCode == 200;
      } catch (_) {
        return false;
      }
    }
    // On Android, always return true here; validation is handled in the widget
    return true;
  }

  void _onConfirmPressed(AppStateProvider appState) async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _errorText = null;
    });
    if (Platform.isLinux) {
      // Allow 'test' to bypass Home Assistant validation for diagnostics
      if (url.trim().toLowerCase() == 'test') {
        await appState.setHomeAssistantUrl('https://example.com');
        _launchWebView('https://example.com');
        return;
      }
      final valid = await _validateUrl(url);
      if (valid) {
        await appState.setHomeAssistantUrl(url);
        _launchWebView(url);
      } else {
        setState(() {
          _errorText = 'Could not reach Home Assistant at that URL.';
        });
      }
    } else if (Platform.isAndroid) {
      setState(() {
        _pendingAndroidValidation = true;
        _pendingUrl = url;
        _webviewLaunched = true;
      });
    }
  }

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  void _launchWebView(String url) async {
    if (Platform.isLinux) {
      // Diagnostic: print the URL being launched
      print('[Linux] Launching webview with URL: $url');
      String launchUrl =
          url.trim().toLowerCase() == 'test' ? 'https://example.com' : url;
      try {
        final webview = await WebviewWindow.create(
          configuration: CreateConfiguration(
            openFullscreen: true,
            forceNativeChromeless: true,
          ),
        );
        webview.launch(launchUrl);
        setState(() {
          _linuxLoadFailed = false;
          _linuxLastError = null;
        });
      } catch (e) {
        setState(() {
          _linuxLoadFailed = true;
          _linuxLastError = e.toString();
        });
      }
    } else if (Platform.isAndroid) {
      setState(() {
        _webviewLaunched = true;
      });
    }
  }

  void _retryLaunch(AppStateProvider appState) {
    setState(() {
      _webviewLaunched = false;
      _loadFailed = false;
      _lastError = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _launchWebView(appState.homeAssistantUrl!);
    });
  }

  @override
  Widget build(BuildContext context) {
    final appState = Provider.of<AppStateProvider>(context);
    if (!appState.isConfigured) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('Enter your Home Assistant URL:'),
                TextField(
                  controller: _urlController,
                  decoration: InputDecoration(
                    hintText: 'https://your-ha.local',
                    errorText: _errorText,
                  ),
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => _onConfirmPressed(appState),
                  child: const Text('Confirm'),
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () async {
                    await appState.resetConfiguration();
                    setState(() {
                      _urlController.clear();
                      _errorText = null;
                      _webviewLaunched = false;
                      _pendingAndroidValidation = false;
                      _pendingUrl = null;
                    });
                  },
                  child: const Text('Reset Configuration'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                  ),
                ),
                if (Platform.isAndroid &&
                    _pendingAndroidValidation &&
                    _pendingUrl != null)
                  Expanded(
                    child: AndroidWebViewWidget(
                      url: _pendingUrl!,
                      onSuccess: () async {
                        setState(() {
                          _pendingAndroidValidation = false;
                          _errorText = null;
                        });
                        await appState.setHomeAssistantUrl(_pendingUrl!);
                      },
                      onError: (err) {
                        setState(() {
                          _pendingAndroidValidation = false;
                          _webviewLaunched = false;
                          _errorText = 'Could not load page: ' + err;
                        });
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    if (!_webviewLaunched) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _launchWebView(appState.homeAssistantUrl!);
      });
      _webviewLaunched = true;
    }
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (Platform.isLinux && _linuxLoadFailed)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                      'Failed to launch window: ${_linuxLastError ?? "Unknown error"}',
                      style: const TextStyle(color: Colors.red)),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () {
                      setState(() {
                        _linuxLoadFailed = false;
                        _linuxLastError = null;
                      });
                      _launchWebView(appState.homeAssistantUrl!);
                    },
                    child: const Text('Retry'),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton(
                    onPressed: () async {
                      await appState.resetConfiguration();
                      setState(() {
                        _webviewLaunched = false;
                        _linuxLoadFailed = false;
                        _linuxLastError = null;
                        _errorText = null;
                        _urlController.clear();
                      });
                    },
                    child: const Text('Reset Configuration'),
                    style:
                        ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  ),
                ],
              )
            else if (Platform.isAndroid &&
                _webviewLaunched &&
                appState.isConfigured &&
                !_loadFailed)
              Expanded(
                child: AndroidWebViewWidget(
                  url: appState.homeAssistantUrl!,
                  onError: (err) {
                    setState(() {
                      _loadFailed = true;
                      _lastError = err;
                    });
                  },
                ),
              )
            else if (_loadFailed)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                      'Failed to load Home Assistant: ${_lastError ?? "Unknown error"}',
                      style: const TextStyle(color: Colors.red)),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => _retryLaunch(appState),
                    child: const Text('Retry'),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton(
                    onPressed: () async {
                      await appState.resetConfiguration();
                      setState(() {
                        _webviewLaunched = false;
                        _loadFailed = false;
                        _lastError = null;
                        _urlController.clear();
                      });
                    },
                    child: const Text('Reset Configuration'),
                    style:
                        ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  ),
                ],
              )
            else
              const Text('Webview launched in separate window.'),
            if (!(Platform.isAndroid &&
                    _webviewLaunched &&
                    appState.isConfigured) &&
                !_loadFailed &&
                !(Platform.isLinux && _linuxLoadFailed))
              Padding(
                padding: const EdgeInsets.only(top: 16.0),
                child: ElevatedButton(
                  onPressed: () async {
                    await appState.resetConfiguration();
                    setState(() {
                      _webviewLaunched = false;
                      _errorText = null;
                      _urlController.clear();
                    });
                  },
                  child: const Text('Reset Configuration'),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
