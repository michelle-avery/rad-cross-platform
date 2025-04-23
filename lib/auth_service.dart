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
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'oauth_config.dart';
import 'secure_token_storage.dart';

enum AuthState {
  unauthenticated,
  authenticating,
  exchanging,
  authenticated,
  error,
}

class AuthService extends ChangeNotifier {
  AuthState _state = AuthState.unauthenticated;
  String? _errorMessage;
  Map<String, dynamic>? _tokens;
  String? _hassUrl;
  String? _pendingState;

  AuthState get state => _state;
  String? get errorMessage => _errorMessage;
  Map<String, dynamic>? get tokens => _tokens;
  String? get hassUrl => _hassUrl;

  /// Start the OAuth authentication process.
  /// Returns the authorization URL to open in a browser or webview.
  Future<String> startAuth(String hassUrl) async {
    _hassUrl = hassUrl;
    _pendingState = OAuthConfig.generateState();
    _state = AuthState.authenticating;
    notifyListeners();
    return OAuthConfig.buildAuthUrl(hassUrl, _pendingState!);
  }

  /// Call this when the app receives a redirect with an authorization code.
  /// [code] is the authorization code, [state] is the returned state.
  Future<void> handleAuthCode(String code, String state) async {
    print('[AuthService] handleAuthCode called with code=$code, state=$state');
    if (state != _pendingState) {
      print(
          '[AuthService] State mismatch: expected $_pendingState, got $state');
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
          'redirect_uri': OAuthConfig.buildRedirectUri(_hassUrl!),
        },
      );
      print(
          '[AuthService] Token endpoint response: status={response.statusCode}, body={response.body}');
      if (response.statusCode == 200) {
        _tokens = json.decode(response.body);
        print('[AuthService] Tokens received: \\${json.encode(_tokens)}');
        await SecureTokenStorage.saveTokens(response.body);
        // Immediately verify that tokens are saved and can be loaded
        final verify = await SecureTokenStorage.readTokens();
        print(
            '[AuthService] SecureTokenStorage.readTokens after save: $verify');
        _state = AuthState.authenticated;
        _errorMessage = null;
      } else {
        _state = AuthState.error;
        _errorMessage = 'Token exchange failed: {response.body}';
      }
    } catch (e) {
      print('[AuthService] Exception during token exchange: $e');
      _state = AuthState.error;
      _errorMessage = 'Network error: $e';
    }
    notifyListeners();
  }

  /// Load tokens from secure storage (if any)
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

  /// Log out and clear tokens
  Future<void> logout() async {
    await SecureTokenStorage.deleteTokens();
    _tokens = null;
    _state = AuthState.unauthenticated;
    notifyListeners();
  }
}
