import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'dart:io';
import 'package:provider/provider.dart';
import 'app_state_provider.dart';
import 'android_webview_widget.dart';
import 'auth_service.dart';
import 'package:webview_flutter/webview_flutter.dart' as android_webview;
import 'webview_controller.dart';
import 'package:flutter/foundation.dart';
import 'screens/auth_screen.dart';

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
            // Use the imported AuthScreen
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
