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
import 'package:logging/logging.dart';
import '../secure_token_storage.dart';
import '../oauth_config.dart';

final _log = Logger('AuthService');

// Custom Exceptions for Refresh Failures
class TemporaryAuthRefreshException implements Exception {
  final String message;
  TemporaryAuthRefreshException(this.message);
  @override
  String toString() => 'TemporaryAuthRefreshException: $message';
}

class PermanentAuthRefreshException implements Exception {
  final String message;
  PermanentAuthRefreshException(this.message);
  @override
  String toString() => 'PermanentAuthRefreshException: $message';
}

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

  Future<String?> startAuthFlow() async {
    if (_hassUrl == null) {
      throw StateError('Home Assistant URL not set.');
    }
    _closeLinuxAuthWebview();

    _pendingState = OAuthConfig.generateState();
    final authUrl = OAuthConfig.buildAuthUrl(_hassUrl!, _pendingState!);
    _log.info('Generated Auth URL state: $_pendingState');
    _state = AuthState.authenticating;
    notifyListeners();

    if (Platform.isAndroid) {
      _log.info('Starting Android auth flow, returning URL.');
      return authUrl;
    } else if (Platform.isLinux) {
      _log.info('Starting Linux auth flow internally.');
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
      _log.info('URL set and validated: $_hassUrl');
      return _hassUrl!;
    } catch (e, stackTrace) {
      _log.severe('URL validation failed.', e, stackTrace);
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
    _log.info('Generated Auth URL state: $_pendingState');
    return authUri.toString();
  }

  Future<void> handleAuthCode(String code, String receivedState) async {
    _log.info('handleAuthCode called with code=$code, state=$receivedState');
    if (receivedState != _pendingState) {
      _log.warning(
          'State mismatch: expected $_pendingState, got $receivedState');
      _state = AuthState.error;
      _errorMessage = 'State mismatch. Possible CSRF attack.';
      notifyListeners();
      return;
    }
    _state = AuthState.exchanging;
    notifyListeners();
    try {
      _log.info('Exchanging code for tokens...');
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
      _log.fine(
          'Token endpoint response: status=${response.statusCode}, body=${response.body}');
      if (response.statusCode == 200) {
        _tokens = json.decode(response.body);
        _log.info('Tokens received successfully.');
        await SecureTokenStorage.saveTokens(response.body);
        _updateTokenExpiryTime();
        final verify = await SecureTokenStorage.readTokens();
        _log.fine(
            'SecureTokenStorage.readTokens after save: ${verify != null ? "found" : "not found"}');
        _state = AuthState.authenticated;
        _errorMessage = null;
      } else {
        _state = AuthState.error;
        _errorMessage = 'Token exchange failed: ${response.body}';
        _log.severe(
            'Token exchange failed: ${response.statusCode} ${response.body}');
      }
    } catch (e, stackTrace) {
      _log.severe('Exception during token exchange.', e, stackTrace);
      _state = AuthState.error;
      _errorMessage = 'Network error: $e';
    }
    notifyListeners();
    if (Platform.isLinux) {
      _closeLinuxAuthWebview();
    }
  }

  Future<void> loadTokens() async {
    _log.info('loadTokens called');
    final jsonStr = await SecureTokenStorage.readTokens();
    _log.fine(
        'SecureTokenStorage.readTokens returned: ${jsonStr != null ? "found" : "not found"}');
    if (jsonStr != null) {
      try {
        _tokens = json.decode(jsonStr);
        _updateTokenExpiryTime();
      } catch (e, stackTrace) {
        _log.severe('Error decoding stored tokens.', e, stackTrace);
        await logout();
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      _hassUrl = prefs.getString('home_assistant_url');

      if (_hassUrl != null && _hassUrl!.isNotEmpty) {
        _state = AuthState.authenticated;
        _log.info('Tokens and URL loaded: $_hassUrl');
      } else {
        _log.warning('No Home Assistant URL found in prefs.');
        _tokens = null;
        _hassUrl = null;
        _state = AuthState.unauthenticated;
        await logout();
        return;
      }
    } else {
      _tokens = null;
      _hassUrl = null;
      _state = AuthState.unauthenticated;
      _log.info('No tokens found, state set to unauthenticated');
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
        _log.fine('Token expiry calculated: $_tokenExpiryTime');
      } else {
        _tokenExpiryTime = null;
        _log.warning('Invalid expires_in value: $expiresIn');
      }
    } else {
      _tokenExpiryTime = null;
      _log.fine('No expires_in found in tokens.');
    }
  }

  bool _isTokenExpired() {
    if (_tokens == null || !_tokens!.containsKey('access_token')) {
      return true;
    }
    if (_tokenExpiryTime == null) {
      _log.warning('Token expiry time unknown, assuming potentially expired.');
      return true;
    }
    return DateTime.now().isAfter(_tokenExpiryTime!);
  }

  Future<void> _refreshToken() async {
    _log.info('Attempting token refresh...');
    if (_hassUrl == null ||
        _tokens == null ||
        !_tokens!.containsKey('refresh_token')) {
      _log.warning(
          'Refresh prerequisites failed: Missing URL, tokens, or refresh_token.');
      await logout();
      _errorMessage = 'Cannot refresh token: Missing required data.';
      _state = AuthState.error;
      notifyListeners();
      throw PermanentAuthRefreshException(
          'Missing URL, tokens, or refresh_token.');
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

      _log.fine(
          'Refresh token response: status=${response.statusCode}, body=${response.body}');

      if (response.statusCode >= 200 && response.statusCode < 300) {
        _tokens = json.decode(response.body);

        if (!_tokens!.containsKey('refresh_token')) {
          _tokens!['refresh_token'] = refreshToken;
          _log.info(
              'Refresh response missing refresh_token, preserving old one.');
        }
        await SecureTokenStorage.saveTokens(json.encode(_tokens));
        _updateTokenExpiryTime();
        _log.info('Token refresh successful.');
        notifyListeners();
        return;
      } else if (response.statusCode >= 500 && response.statusCode < 600) {
        final errorMsg =
            'Temporary server error during refresh: ${response.statusCode} ${response.body}';
        _log.warning(errorMsg);
        throw TemporaryAuthRefreshException(errorMsg);
      } else {
        final errorMsg =
            'Permanent error during refresh: ${response.statusCode} ${response.body}';
        _log.severe(errorMsg);
        await logout();
        _errorMessage =
            'Authentication expired or invalid. Please log in again.';
        _state = AuthState.error;
        notifyListeners();
        throw PermanentAuthRefreshException(errorMsg);
      }
    } catch (e, stackTrace) {
      final errorMsg = 'Network exception during token refresh: $e';
      _log.warning(errorMsg, e, stackTrace);
      throw TemporaryAuthRefreshException(errorMsg);
    }
  }

  Future<String?> getValidAccessToken() async {
    if (_isTokenExpired()) {
      _log.info('Access token expired or missing. Attempting refresh.');
      try {
        await _refreshToken();
      } on TemporaryAuthRefreshException catch (e) {
        _log.warning('Temporary failure during token refresh: $e');
        rethrow;
      } on PermanentAuthRefreshException catch (e) {
        _log.severe('Permanent failure during token refresh: $e');
        return null;
      } catch (e, stackTrace) {
        _log.severe('Unexpected error during token refresh.', e, stackTrace);
        if (_state != AuthState.error) {
          _state = AuthState.error;
          _errorMessage = 'Unexpected error during token refresh: $e';
          notifyListeners();
        }
        return null;
      }
    }

    if (_tokens != null && _tokens!.containsKey('access_token')) {
      return _tokens!['access_token'] as String?;
    } else {
      _log.warning('No access token available even after check/refresh.');
      return null;
    }
  }

  Future<bool> forceRefreshToken() async {
    _log.info('Force refreshing token...');
    try {
      await _refreshToken();
      _log.info('Force token refresh successful.');
      return true;
    } on TemporaryAuthRefreshException catch (e) {
      _log.warning('Force token refresh failed temporarily: $e');
      return false;
    } on PermanentAuthRefreshException catch (e) {
      _log.severe('Force token refresh failed permanently: $e');
      return false;
    } catch (e, s) {
      _log.severe('Unexpected exception during forceRefreshToken.', e, s);
      if (_state != AuthState.error) {
        _state = AuthState.error;
        _errorMessage = 'Unexpected error during force token refresh: $e';
        notifyListeners();
      }
      return false;
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
    } catch (e, stackTrace) {
      _log.severe('Error creating auth webview.', e, stackTrace);
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
      } catch (e, stackTrace) {
        _log.warning('Error during cleanup.', e, stackTrace);
      } finally {
        if (!codeHandled && _state == AuthState.authenticating) {
          _log.info('Auth cancelled or failed during cleanup');
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
              _log.info('Code received: $code, state: $state');
              await handleAuthCode(code, state);
            } else {
              throw Exception('Missing code or state in redirect URI.');
            }
          } catch (e, stackTrace) {
            _log.severe('Error handling redirect.', e, stackTrace);
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
      _log.fine('WebView closed.');
      if (!codeHandled && _state == AuthState.authenticating) {
        _log.info('Auth cancelled by user closing window.');
        _state = AuthState.unauthenticated;
        _errorMessage = 'Authentication cancelled.';
        notifyListeners();
      }
      cleanup();
    });
    _linuxAuthWebview!.onClose.whenComplete(() {
      _log.fine('WebView closed (duplicate listener).');
      if (!codeHandled && _state == AuthState.authenticating) {
        _log.info(
            'Auth cancelled by user closing window (duplicate listener).');
        _state = AuthState.unauthenticated;
        _errorMessage = 'Authentication cancelled.';
        notifyListeners();
      }
      cleanup();
    });

    try {
      _linuxAuthWebview!.launch(authUrl);
    } catch (e, stackTrace) {
      _log.severe('Error launching URL in auth webview.', e, stackTrace);
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
