import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';
import '../providers/app_state_provider.dart';
import '../services/auth_service.dart';
import 'oauth_webview_screen.dart';
import 'dart:io';
import 'package:logging/logging.dart';

final _log = Logger('AuthScreen');

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
  final _customDeviceIdController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;
  String? _httpWarningMessage;

  @override
  void initState() {
    super.initState();
    _urlController.addListener(_updateHttpWarning);
    // Initialize URL from provider if available
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _urlController.text.isEmpty) {
        final initialUrl = Provider.of<AppStateProvider>(context, listen: false)
            .homeAssistantUrl;
        if (initialUrl != null) {
          _urlController.text = initialUrl;
          _updateHttpWarning();
        }
      }
    });
  }

  void _updateHttpWarning() {
    if (_urlController.text.trim().toLowerCase().startsWith('http://')) {
      setState(() {
        _httpWarningMessage =
            'Warning: Using HTTP is insecure. HTTPS is recommended.';
      });
    } else {
      setState(() {
        _httpWarningMessage = null;
      });
    }
  }

  @override
  void dispose() {
    _urlController.removeListener(_updateHttpWarning);
    _urlController.dispose();
    _customDeviceIdController.dispose();
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
      if (appState.deviceId == null || appState.deviceId!.isEmpty) {
        _log.info(
            'Device ID not set, configuring initial ID. Custom input: "${_customDeviceIdController.text}"');
        await appState.configureInitialDeviceId(
            _customDeviceIdController.text.trim().isEmpty
                ? null
                : _customDeviceIdController.text.trim());
      } else {
        _log.info(
            'Device ID already set (${appState.deviceId}), skipping initial configuration.');
      }

      final validatedUrl =
          await authService.validateAndSetUrl(_urlController.text);
      await appState.setHomeAssistantUrl(validatedUrl);

      final authUrl = await authService.startAuthFlow();

      if (Platform.isAndroid) {
        if (authUrl == null) {
          throw StateError('startAuthflow returned null for Android');
        }
        void handleAndroidAuthCode(String code, String state) async {
          if (!mounted) return;
          try {
            final authService =
                Provider.of<AuthService>(context, listen: false);
            await authService.handleAuthCode(code, state);
          } catch (e, s) {
            _log.severe('Error handling auth code from Android: $e', e, s);
            if (mounted) {
              setState(() {
                _errorMessage = 'Authentication failed: ${e.toString()}';
                _isLoading = false;
              });
            }
          }
        }

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
        _log.info('Linux auth flow initiated by AuthService.');
      }
    } catch (e, s) {
      _log.severe('Login Error: $e', e, s);
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
    final appState = Provider.of<AppStateProvider>(context);
    final authService = Provider.of<AuthService>(context);
    final authState = authService.state;
    final bool showMigrationOption =
        appState.deviceId == null || appState.deviceId!.isEmpty;

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
                              onChanged: (_) => _updateHttpWarning(),
                            ),
                            if (_httpWarningMessage != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 8.0),
                                child: Text(
                                  _httpWarningMessage!,
                                  style: const TextStyle(
                                      color: Colors.orangeAccent, fontSize: 13),
                                ),
                              ),
                            if (showMigrationOption) ...[
                              const SizedBox(height: 16),
                              ExpansionTile(
                                title: const Text(
                                  'Advanced: Migration Settings',
                                  style:
                                      TextStyle(fontSize: 14, color: textColor),
                                ),
                                tilePadding: EdgeInsets.zero,
                                childrenPadding:
                                    const EdgeInsets.only(top: 8.0),
                                children: [
                                  Text(
                                    'If migrating from an older version of RAD, enter your previous Device ID here to keep the same entity in Home Assistant. Otherwise, leave this blank.',
                                    style: TextStyle(
                                        fontSize: 13,
                                        color: textColor.withOpacity(0.7)),
                                  ),
                                  const SizedBox(height: 8),
                                  TextFormField(
                                    controller: _customDeviceIdController,
                                    decoration: InputDecoration(
                                      hintText: 'Optional: Previous Device ID',
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 12.0, vertical: 12.0),
                                      border: OutlineInputBorder(
                                        borderRadius:
                                            BorderRadius.circular(6.0),
                                        borderSide: const BorderSide(
                                            color: inputBorderColor,
                                            width: 1.0),
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius:
                                            BorderRadius.circular(6.0),
                                        borderSide: const BorderSide(
                                            color: inputBorderColor,
                                            width: 1.0),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius:
                                            BorderRadius.circular(6.0),
                                        borderSide: const BorderSide(
                                            color: primaryColor, width: 1.0),
                                      ),
                                      isDense: true,
                                    ),
                                    autocorrect: false,
                                    enableSuggestions: false,
                                  ),
                                ],
                              ),
                            ],
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
