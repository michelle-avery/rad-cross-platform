import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';
import '../providers/app_state_provider.dart';
import '../services/auth_service.dart';
import 'oauth_webview_screen.dart';
import 'dart:io';

const Color primaryColor = Color(0xFF40C4FF);
const Color lightBlue = Color(0xFFE1F5FE);
const Color textColor = Color(0xFF2C3E50);
const Color backgroundColor = Color(0xFFF8F9FA);
const Color errorColor = Color(0xFFEF5350);
const Color errorBackgroundColor = Color(0xFFFFEBEE);
const Color errorBorderColor = Color(0xFFFFCDD2);
const Color inputBorderColor = Color(0xFFE2E8F0);
const Color disabledButtonColor = Color(0xFF90CAF9);
const Color hoverButtonColor = Color(0xFF00B0FF);

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
    final authService = Provider.of<AuthService>(context);
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
            _errorMessage = authService.errorMessage ??
                'Authentication cancelled or failed.';
          });
        }
      });
    }

    return Scaffold(
      backgroundColor: backgroundColor,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SvgPicture.asset(
                  'assets/images/rad_logo.svg',
                  width: 80,
                  height: 80,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Remote Assist Display',
                  style: TextStyle(
                    color: textColor,
                    fontSize: 32,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                Container(
                  padding: const EdgeInsets.all(32.0),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12.0),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 6.0,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Connect to Home Assistant',
                        style: TextStyle(
                          color: textColor,
                          fontSize: 24,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      Form(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TextFormField(
                              controller: _urlController,
                              decoration: InputDecoration(
                                hintText: 'https://your-home-assistant-url',
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12.0, vertical: 12.0),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(6.0),
                                  borderSide: const BorderSide(
                                      color: inputBorderColor, width: 1.0),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(6.0),
                                  borderSide: const BorderSide(
                                      color: inputBorderColor, width: 1.0),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(6.0),
                                  borderSide: const BorderSide(
                                      color: primaryColor, width: 1.0),
                                ),
                                errorBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(6.0),
                                  borderSide: const BorderSide(
                                      color: errorColor, width: 1.0),
                                ),
                                focusedErrorBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(6.0),
                                  borderSide: const BorderSide(
                                      color: errorColor, width: 1.0),
                                ),
                                isDense: true,
                              ),
                              keyboardType: TextInputType.url,
                              autocorrect: false,
                              enableSuggestions: false,
                            ),
                            const SizedBox(height: 8),
                            Visibility(
                              visible: _errorMessage != null,
                              maintainState: true,
                              maintainAnimation: true,
                              maintainSize: true,
                              child: Padding(
                                padding: const EdgeInsets.only(top: 0),
                                child: Text(
                                  _errorMessage ?? '',
                                  style: const TextStyle(
                                    color: errorColor,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            ElevatedButton(
                              onPressed: _isLoading ? null : _login,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: primaryColor,
                                foregroundColor: Colors.white,
                                disabledBackgroundColor: disabledButtonColor,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12.0),
                                minimumSize: const Size(double.infinity, 45),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(6.0),
                                ),
                              ),
                              child: _isLoading
                                  ? const Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        SizedBox(
                                          height: 20,
                                          width: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        ),
                                        SizedBox(width: 12),
                                        Text('Connecting...'),
                                      ],
                                    )
                                  : const Text('Connect'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
