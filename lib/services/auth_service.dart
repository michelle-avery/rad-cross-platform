/// AuthService handles the OAuth authentication flow for Home Assistant IndieAuth.
/// It uses [OAuthConfig] for URL construction and [SecureTokenStorage] for secure token storage.
///
/// Responsibilities:
///   - Build the authorization URL
///   - Generate and validate state
///   - Exchange authorization code for tokens
///   - Store and retrieve tokens securely
///   - Expose authentication state and tokens
///   - Provide hooks for platform-specific redirect handling

import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../secure_token_storage.dart';
import '../oauth_config.dart';

enum AuthState {
  unauthenticated,
  authenticating,
  exchanging,
  authenticated,
  error,
}

class AuthService with ChangeNotifier {
  AuthState _state = AuthState.unauthenticated;
  String? _errorMessage;
  Map<String, dynamic>? _tokens;
  DateTime? _tokenExpiryTime;
  String? _hassUrl;
  String? _pendingState;

  Webview? _linuxAuthWebview;

  AuthState get state => _state;
  String? get errorMessage => _errorMessage;
  Map<String, dynamic>? get tokens => _tokens;
  String? get hassUrl => _hassUrl;

  String get redirectUri {
    if (_hassUrl == null) {
      throw StateError('Cannot get redirectUri before hassUrl is set.');
    }
    return OAuthConfig.buildRedirectUri(_hassUrl!);
  }

  /// Start the platform-specific authentication flow.
  Future<String?> startAuthFlow() async {
    if (_hassUrl == null) {
      throw StateError('Home Assistant URL not set.');
    }
    _closeLinuxAuthWebview();

    _pendingState = OAuthConfig.generateState();
    final authUrl = OAuthConfig.buildAuthUrl(_hassUrl!, _pendingState!);
    print('[AuthService] Generated Auth URL state: $_pendingState');
    _state = AuthState.authenticating;
    notifyListeners();

    if (Platform.isAndroid) {
      print('[AuthService] Starting Android auth flow, returning URL.');
      return authUrl;
    } else if (Platform.isLinux) {
      print('[AuthService] Starting Linux auth flow internally.');
      _startLinuxAuthFlowInternal(authUrl);
      return null;
    } else {
      _state = AuthState.error;
      _errorMessage = 'Unsupported platform for authentication flow.';
      notifyListeners();
      throw UnsupportedError('Unsupported platform for authentication flow.');
    }
  }

  Future<String> validateAndSetUrl(String url) async {
    Uri uri;
    try {
      uri = Uri.parse(url);
      if (!uri.isAbsolute || (uri.scheme != 'http' && uri.scheme != 'https')) {
        throw const FormatException('Invalid URL scheme. Use http or https.');
      }
      String normalizedUrl = uri.toString();
      if (normalizedUrl.endsWith('/')) {
        normalizedUrl = normalizedUrl.substring(0, normalizedUrl.length - 1);
      }
      _hassUrl = normalizedUrl;
      print('[AuthService] URL set and validated: $_hassUrl');
      return _hassUrl!;
    } catch (e) {
      print('[AuthService] URL validation failed: $e');
      throw FormatException('Invalid URL format: ${e.toString()}');
    }
  }

  String getAuthorizationUrl() {
    if (_hassUrl == null) {
      throw StateError('Home Assistant URL not set.');
    }
    _pendingState = OAuthConfig.generateState();
    final Uri authUri = Uri.parse('$_hassUrl/auth/authorize').replace(
      queryParameters: {
        'response_type': 'code',
        'client_id': OAuthConfig.buildClientId(_hassUrl!),
        'redirect_uri': OAuthConfig.redirectUri,
        'state': _pendingState,
      },
    );
    print('[AuthService] Generated Auth URL state: $_pendingState');
    return authUri.toString();
  }

  Future<void> handleAuthCode(String code, String receivedState) async {
    print(
        '[AuthService] handleAuthCode called with code=$code, state=$receivedState');
    if (receivedState != _pendingState) {
      print(
          '[AuthService] State mismatch: expected $_pendingState, got $receivedState');
      _state = AuthState.error;
      _errorMessage = 'State mismatch. Possible CSRF attack.';
      notifyListeners();
      return;
    }
    _state = AuthState.exchanging;
    notifyListeners();
    try {
      print('[AuthService] Exchanging code for tokens...');
      final response = await http.post(
        Uri.parse('$_hassUrl/auth/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'authorization_code',
          'code': code,
          'client_id': OAuthConfig.buildClientId(_hassUrl!),
          'redirect_uri': OAuthConfig.redirectUri,
        },
      );
      print(
          '[AuthService] Token endpoint response: status=${response.statusCode}, body=${response.body}');
      if (response.statusCode == 200) {
        _tokens = json.decode(response.body);
        print('[AuthService] Tokens received: ${json.encode(_tokens)}');
        await SecureTokenStorage.saveTokens(response.body);
        _updateTokenExpiryTime();
        final verify = await SecureTokenStorage.readTokens();
        print(
            '[AuthService] SecureTokenStorage.readTokens after save: $verify');
        _state = AuthState.authenticated;
        _errorMessage = null;
      } else {
        _state = AuthState.error;
        _errorMessage = 'Token exchange failed: ${response.body}';
      }
    } catch (e) {
      print('[AuthService] Exception during token exchange: $e');
      _state = AuthState.error;
      _errorMessage = 'Network error: $e';
    }
    notifyListeners();
    if (Platform.isLinux) {
      _closeLinuxAuthWebview();
    }
  }

  Future<void> loadTokens() async {
    print('[AuthService] loadTokens called');
    final jsonStr = await SecureTokenStorage.readTokens();
    print('[AuthService] SecureTokenStorage.readTokens returned: $jsonStr');
    if (jsonStr != null) {
      try {
        _tokens = json.decode(jsonStr);
        _updateTokenExpiryTime();
      } catch (e) {
        print('[AuthService] Error decoding stored tokens: $e');
        await logout();
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      _hassUrl = prefs.getString('home_assistant_url');

      if (_hassUrl != null && _hassUrl!.isNotEmpty) {
        _state = AuthState.authenticated;
        print('[AuthService] Tokens and URL loaded: $_hassUrl');
      } else {
        print('[AuthService] No Home Assistant URL found in prefs.');
        _tokens = null;
        _hassUrl = null;
        _state = AuthState.unauthenticated;
        await logout();
      }
    } else {
      _tokens = null;
      _hassUrl = null;
      _state = AuthState.unauthenticated;
      print('[AuthService] No tokens found, state set to unauthenticated');
    }
    notifyListeners();
  }

  Future<void> logout() async {
    await SecureTokenStorage.deleteTokens();
    _tokens = null;
    _tokenExpiryTime = null;
    _hassUrl = null;
    _pendingState = null;
    _closeLinuxAuthWebview();
    _state = AuthState.unauthenticated;
    notifyListeners();
  }

  void _updateTokenExpiryTime() {
    if (_tokens != null && _tokens!.containsKey('expires_in')) {
      final expiresIn = _tokens!['expires_in'];
      if (expiresIn is int) {
        _tokenExpiryTime =
            DateTime.now().add(Duration(seconds: expiresIn - 60));
        print('[AuthService] Token expiry calculated: $_tokenExpiryTime');
      } else {
        _tokenExpiryTime = null;
        print('[AuthService] Invalid expires_in value: $expiresIn');
      }
    } else {
      _tokenExpiryTime = null;
      print('[AuthService] No expires_in found in tokens.');
    }
  }

  bool _isTokenExpired() {
    if (_tokens == null || !_tokens!.containsKey('access_token')) {
      return true;
    }
    if (_tokenExpiryTime == null) {
      print(
          '[AuthService] Token expiry time unknown, assuming potentially expired.');
      return true;
    }
    return DateTime.now().isAfter(_tokenExpiryTime!);
  }

  Future<bool> _refreshToken() async {
    print('[AuthService] Attempting token refresh...');
    if (_hassUrl == null ||
        _tokens == null ||
        !_tokens!.containsKey('refresh_token')) {
      print(
          '[AuthService] Refresh failed: Missing URL, tokens, or refresh_token.');
      return false;
    }

    final refreshToken = _tokens!['refresh_token'];
    final clientId = OAuthConfig.buildClientId(_hassUrl!);

    try {
      final response = await http.post(
        Uri.parse('$_hassUrl/auth/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'refresh_token',
          'refresh_token': refreshToken,
          'client_id': clientId,
        },
      );

      print(
          '[AuthService] Refresh token response: status=${response.statusCode}, body=${response.body}');

      if (response.statusCode == 200) {
        _tokens = json.decode(response.body);

        if (!_tokens!.containsKey('refresh_token')) {
          _tokens!['refresh_token'] = refreshToken;
          print(
              '[AuthService] Refresh response missing refresh_token, preserving old one.');
        }
        await SecureTokenStorage.saveTokens(json.encode(_tokens));
        _updateTokenExpiryTime();
        print('[AuthService] Token refresh successful.');
        notifyListeners();
        return true;
      } else {
        print(
            '[AuthService] Refresh failed: Server returned status ${response.statusCode}');
        await logout();
        _errorMessage = 'Authentication expired. Please log in again.';
        _state = AuthState.error;
        notifyListeners();
        return false;
      }
    } catch (e) {
      print('[AuthService] Exception during token refresh: $e');
      _errorMessage = 'Network error during token refresh: $e';
      _state = AuthState.error;
      notifyListeners();
      return false;
    }
  }

  Future<String?> getValidAccessToken() async {
    if (_isTokenExpired()) {
      print(
          '[AuthService] Access token expired or missing. Attempting refresh.');
      final refreshed = await _refreshToken();
      if (!refreshed) {
        print('[AuthService] Failed to refresh token.');
        return null;
      }
    }

    if (_tokens != null && _tokens!.containsKey('access_token')) {
      return _tokens!['access_token'] as String?;
    } else {
      print(
          '[AuthService] No access token available even after check/refresh.');
      return null;
    }
  }

  Future<void> _startLinuxAuthFlowInternal(String authUrl) async {
    try {
      _linuxAuthWebview = await WebviewWindow.create(
        configuration: CreateConfiguration(
          forceNativeChromeless: true,
          openFullscreen: true,
        ),
      );
    } catch (e) {
      print('[AuthService Linux] Error createing auth webview: $e');
      _state = AuthState.error;
      _errorMessage = 'Failed to create Linux WebView: $e';
      notifyListeners();
      return;
    }

    bool codeHandled = false;
    final redirectUri = OAuthConfig.buildRedirectUri(_hassUrl!);

    void cleanup() {
      try {
        if (_linuxAuthWebview != null) {
          _linuxAuthWebview?.setOnUrlRequestCallback(null);
          _closeLinuxAuthWebview();
        }
      } catch (e) {
        print('[AuthService Linux] Error during cleanup: $e');
      } finally {
        if (!codeHandled && _state == AuthState.authenticating) {
          print(['AuthService Linux] Auth cancelled or failed during cleanup']);
          _state = AuthState.unauthenticated;
          _errorMessage = 'Authentication cancelled or failed.';
          notifyListeners();
        }
      }
    }

    _linuxAuthWebview!.setOnUrlRequestCallback((url) {
      if (url.startsWith(redirectUri) && !codeHandled) {
        codeHandled = true;
        Future.microtask(() async {
          try {
            final uri = Uri.parse(url);
            final code = uri.queryParameters['code'];
            final state = uri.queryParameters['state'];
            if (code != null && state != null) {
              print('[AuthService Linux] Code received: $code, state: $state');
              await handleAuthCode(code, state);
            } else {
              throw Exception('Missing code or state in redirect URI.');
            }
          } catch (e) {
            print('[AuthService Linux] Error handling redirect: $e');
            _state = AuthState.error;
            _errorMessage = 'Authentication failed: ${e.toString()}';
            notifyListeners();
            _closeLinuxAuthWebview();
          }
        });
        return false;
      }
      return true;
    });

    _linuxAuthWebview!.onClose.whenComplete(() {
      print('[AuthService Linux] WebView closed.');
      if (!codeHandled && _state == AuthState.authenticating) {
        print('[AuthService Linux] Auth cancelled by user closing window.');
        _state = AuthState.unauthenticated;
        _errorMessage = 'Authentication cancelled.';
        notifyListeners();
      }
      cleanup();
    });

    _linuxAuthWebview!.onClose.whenComplete(() {
      print('[AuthService Linux] WebView closed.');
      if (!codeHandled && _state == AuthState.authenticating) {
        print('[AuthService Linux] Auth cancelled by user closing window.');
        _state = AuthState.unauthenticated;
        _errorMessage = 'Authentication cancelled.';
        notifyListeners();
      }
      cleanup();
    });

    try {
      _linuxAuthWebview!.launch(authUrl);
    } catch (e) {
      print('[AuthService Linux] Error launching URL in auth webview: $e');
      _state = AuthState.error;
      _errorMessage = 'Could not load login page: $e';
      notifyListeners();
      cleanup();
    }
  }

  void _closeLinuxAuthWebview() {
    if (_linuxAuthWebview != null) {
      _linuxAuthWebview!.close();
      _linuxAuthWebview = null;
    }
  }

  static String generateTokenInjectionJs(String accessToken,
      String refreshToken, int expiresIn, String clientId, String hassUrl) {
    final expires = DateTime.now().millisecondsSinceEpoch + (expiresIn * 1000);
    final hassTokensJson = json.encode({
      "access_token": accessToken,
      "refresh_token": refreshToken,
      "expires_in": expiresIn,
      "token_type": "Bearer",
      "clientId": clientId,
      "hassUrl": hassUrl,
      "ha_auth_provider": "homeassistant",
      "expires": expires,
    });

    return """
      try {
        // Use JSON.stringify for safety, though hassTokensJson is already a string
        localStorage.setItem("hassTokens", JSON.stringify($hassTokensJson));
        console.log('hassTokens injected successfully.');
        // Navigate to the root dashboard or reload if already there
        // Check if already at root or lovelace before navigating
        if (window.location.pathname !== '/' && !window.location.pathname.startsWith('/lovelace')) {
           console.log('Navigating to /lovelace/0 after token injection.');
           // Use replace to avoid adding the auth page to history
           window.location.replace('/lovelace/0');
        } else {
           console.log('Already at root or lovelace, reloading page after token injection.');
           window.location.reload();
        }
      } catch (e) {
        console.error('Error injecting hassTokens:', e);
      }
    """;
  }
}
