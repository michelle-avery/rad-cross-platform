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
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'secure_token_storage.dart';
import 'oauth_config.dart';

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
  String? _hassUrl;
  String? _pendingState;

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

  /// Start the OAuth authentication process.
  /// Returns the authorization URL to open in a browser or webview.
  Future<String> startAuth(String hassUrl) async {
    _hassUrl = hassUrl;
    _pendingState = OAuthConfig.generateState();
    _state = AuthState.authenticating;
    notifyListeners();
    return OAuthConfig.buildAuthUrl(hassUrl, _pendingState!);
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
    _pendingState = _generateRandomString(32);
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
  }

  Future<void> loadTokens() async {
    print('[AuthService] loadTokens called');
    final jsonStr = await SecureTokenStorage.readTokens();
    print('[AuthService] SecureTokenStorage.readTokens returned: $jsonStr');
    if (jsonStr != null) {
      _tokens = json.decode(jsonStr);
      _state = AuthState.authenticated;
      print('[AuthService] Tokens loaded, state set to authenticated');
    } else {
      _tokens = null;
      _state = AuthState.unauthenticated;
      print('[AuthService] No tokens found, state set to unauthenticated');
    }
    notifyListeners();
  }

  Future<void> logout() async {
    await SecureTokenStorage.deleteTokens();
    _tokens = null;
    _state = AuthState.unauthenticated;
    notifyListeners();
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
        localStorage.setItem("hassTokens", '$hassTokensJson');
        console.log('hassTokens injected successfully.');
        // Navigate to the root dashboard or reload if already there
        if (window.location.pathname !== '/lovelace/0' && window.location.pathname !== '/lovelace') {
           console.log('Navigating to /lovelace/0');
           window.location.replace('/lovelace/0');
        } else {
           console.log('Reloading current page.');
           window.location.reload();
        }
      } catch (e) {
        console.error('Error injecting hassTokens:', e);
      }
    """;
  }
}

String _generateRandomString(int length) {
  const chars =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final random = Random.secure();
  return List.generate(length, (index) => chars[random.nextInt(chars.length)])
      .join();
}
