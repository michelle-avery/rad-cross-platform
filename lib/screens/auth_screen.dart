import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import '../app_state_provider.dart';
import '../auth_service.dart';
import '../oauth_webview.dart'; // Will be moved later

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
    // Initialize URL from provider if available
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _urlController.text.isEmpty) {
        final initialUrl = Provider.of<AppStateProvider>(context, listen: false)
            .homeAssistantUrl;
        if (initialUrl != null) {
          _urlController.text = initialUrl;
        }
      }
    });
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
            // No need to pop here, the main app state change will rebuild MyApp
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

        // Ensure the context is still valid before navigating
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => OAuthWebView(
              // This widget will be moved later
              authUrl: authUrl,
              onAuthCode: handleAndroidAuthCode,
            ),
          ),
        );
        // Re-check mounted status after async gap
        if (mounted && authService.state != AuthState.authenticated) {
          setState(() {
            if (_errorMessage == null) {
              _errorMessage = 'Authentication cancelled or failed.';
            }
            _isLoading = false;
          });
        }
      } else if (Platform.isLinux) {
        // Ensure the context is still valid before starting flow
        if (!mounted) return;
        await _startLinuxAuthFlow(authUrl, authService, validatedUrl);
      } else {
        throw UnsupportedError('Platform not supported for login flow');
      }
    } catch (e) {
      print('[AuthScreen] Login Error: $e');
      // Re-check mounted status after async gap
      if (mounted) {
        setState(() {
          _errorMessage = 'Login failed: ${e.toString()}';
          _isLoading = false;
        });
      }
    }
    // Don't automatically set _isLoading to false here for Linux,
    // as the auth flow runs in a separate window. It's handled in cleanup/onClose.
  }

  Future<void> _startLinuxAuthFlow(
      String authUrl, AuthService authService, String validatedUrl) async {
    _closeLinuxAuthWebview(); // Ensure any previous auth window is closed

    // Check mounted before creating the webview
    if (!mounted) return;

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
          _isLoading = false; // Stop loading if window creation fails
        });
      }
      return;
    }

    // Check mounted again after await
    if (!mounted) {
      _closeLinuxAuthWebview(); // Close if screen disposed during creation
      return;
    }

    bool codeHandled = false;

    void cleanup() {
      // Check mounted before accessing state or webview
      if (!mounted) return;

      try {
        // Check if webview still exists before trying to modify/close
        if (_linuxAuthWebview != null) {
          _linuxAuthWebview?.setOnUrlRequestCallback(null);
          _closeLinuxAuthWebview(); // Use the existing close method
        }
      } catch (e) {
        print('[AuthScreen Linux] Error during cleanup: $e');
      } finally {
        // Only update state if still mounted and loading
        if (mounted && !codeHandled && _isLoading) {
          setState(() {
            _isLoading = false;
            if (_errorMessage == null) {
              _errorMessage = 'Authentication cancelled or failed.';
            }
          });
        }
      }
    }

    final redirectUri = authService.redirectUri;

    _linuxAuthWebview!.setOnUrlRequestCallback((url) {
      // Check mounted before processing callback
      if (!mounted) return false; // Don't navigate if disposed

      if (url.startsWith(redirectUri) && !codeHandled) {
        codeHandled = true; // Prevent multiple handling
        // Use Future.microtask to avoid holding up the callback
        Future.microtask(() async {
          // Check mounted before handling code
          if (!mounted) return;
          try {
            final uri = Uri.parse(url);
            final code = uri.queryParameters['code'];
            final state = uri.queryParameters['state'];

            if (code != null && state != null) {
              await authService.handleAuthCode(code, state);
              // Successful auth state change will trigger rebuild in MyApp
            } else {
              throw Exception('Missing code or state in redirect URI');
            }
          } catch (e) {
            print('[AuthScreen Linux] Error handling redirect: $e');
            if (mounted) {
              setState(() {
                _errorMessage = 'Authentication failed: ${e.toString()}';
                // Keep _isLoading true until cleanup sets it? Or set false here?
                // Let cleanup handle _isLoading based on codeHandled status
              });
            }
          } finally {
            // Check mounted before cleanup
            if (mounted) {
              cleanup();
            }
          }
        });
        return false; // Prevent the webview from navigating to the redirect URI
      }
      return true; // Allow navigation for other URLs
    });

    _linuxAuthWebview!.onClose.whenComplete(() {
      // Check mounted before handling close
      if (mounted && !codeHandled) {
        // Only set cancelled message if not already handled and no other error
        if (_errorMessage == null) {
          setState(() {
            _errorMessage = 'Authentication cancelled.';
          });
        }
      }
      // Always run cleanup, which handles mounted checks and isLoading state
      cleanup();
    });

    // Check mounted before launching URL
    if (!mounted) {
      _closeLinuxAuthWebview();
      return;
    }

    try {
      _linuxAuthWebview!.launch(authUrl);
    } catch (e) {
      print('[AuthScreen Linux] Error launching URL in auth webview: $e');
      if (mounted) {
        setState(() {
          _errorMessage = 'Could not load login page: $e';
          _isLoading = false; // Stop loading if launch fails
        });
      }
      cleanup(); // Cleanup if launch fails
    }
  }

  @override
  Widget build(BuildContext context) {
    // Removed initial URL setting from build, moved to initState
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
                    hintText:
                        'e.g., http://homeassistant.local:8123', // Corrected hint
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
