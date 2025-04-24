import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state_provider.dart';
import '../auth_service.dart';
import 'oauth_webview_screen.dart'; // Corrected import
import 'dart:io';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _urlController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

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
    super.dispose();
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

      final authUrl = await authService.startAuthFlow();

      if (Platform.isAndroid) {
        if (authUrl == null) {
          throw StateError('startAuthflow returned null for Android');
        }
        void handleAndroidAuthCode(String code, String state) async {
          // Check mounted before handling code
          if (!mounted) return;
          try {
            // Get authService again within the callback scope if needed,
            // or ensure it's captured correctly.
            final authService =
                Provider.of<AuthService>(context, listen: false);
            await authService.handleAuthCode(code, state);
            // No need to pop here, OAuthWebViewScreen handles popping itself.
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
              authUrl: authUrl,
              onAuthCode: handleAndroidAuthCode,
            ),
          ),
        );
        final currentAuthService =
            Provider.of<AuthService>(context, listen: false);
        if (mounted && currentAuthService.state != AuthState.authenticated) {
          setState(() {
            if (_errorMessage == null) {
              _errorMessage = 'Authentication cancelled or failed.';
            }
            _isLoading = false;
          });
        }
      } else if (Platform.isLinux) {
        print('[AuthScreen] Linux auth flow initiated by AuthService.');
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
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthService>(
      builder: (context, authService, child) {
        final authState = authService.state;
        if (authState == AuthState.error && _isLoading) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() {
                _isLoading = false;
                _errorMessage = authService.errorMessage ??
                    'An unknown authentication error occurred.';
              });
            }
          });
        } else if (authState == AuthState.unauthenticated &&
            _isLoading &&
            _errorMessage == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() {
                _isLoading = false;
                _errorMessage =
                    authService.errorMessage ?? 'Authentication cancelled.';
              });
            }
          });
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
                        hintText: 'e.g., http://homeassistant.local:8123',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8.0),
                        ),
                      ),
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      enableSuggestions: false,
                    ),
                    const SizedBox(height: 8),
                    if (_errorMessage != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16.0),
                        child: Text(
                          _errorMessage!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: _isLoading ? null : _login,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16.0),
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        foregroundColor:
                            Theme.of(context).colorScheme.onPrimary,
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              height: 24,
                              width: 24,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Text('Log In'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
