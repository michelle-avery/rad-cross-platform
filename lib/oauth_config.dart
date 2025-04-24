/// OAuthConfig centralizes all constants and URL construction logic for Home Assistant IndieAuth.
/// This class is platform-agnostic and should be used by the authentication service.

import 'dart:math';

class OAuthConfig {
  /// The custom URL scheme for deep linking (used for both Android and Linux).
  static const String scheme = "remoteassistdisplay";

  /// The path for the deep link redirect (e.g., remoteassistdisplay://auth).
  static const String callbackPath = "auth";

  /// The path on the Home Assistant instance where the redirect HTML is hosted.
  static const String redirectPath = "/rad-cxp";

  /// OAuth2 response type (authorization code flow).
  static const String responseType = "code";

  /// The redirect URI that the app will handle (deep link).
  static String get redirectUri => "$scheme://$callbackPath";

  /// Generate the client ID from the user's Home Assistant base URL.
  /// The client ID is the URL of the redirect page on the user's HA instance.
  static String buildClientId(String hassBaseUrl) {
    if (hassBaseUrl.endsWith('/')) {
      hassBaseUrl = hassBaseUrl.substring(0, hassBaseUrl.length - 1);
    }
    return '$hassBaseUrl$redirectPath';
  }

  /// Build the redirect URI for Home Assistant (always the app's deep link URI).
  static String buildRedirectUri(String hassBaseUrl) {
    return redirectUri;
  }

  /// Generate a random state string to prevent CSRF attacks.
  static String generateState() {
    const charset =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random.secure();
    return String.fromCharCodes(Iterable.generate(
        32, (_) => charset.codeUnitAt(random.nextInt(charset.length))));
  }

  /// Build the full Home Assistant authorization URL.
  static String buildAuthUrl(String hassUrl, String state) {
    if (hassUrl.endsWith('/')) {
      hassUrl = hassUrl.substring(0, hassUrl.length - 1);
    }
    final encodedClientId = Uri.encodeComponent(buildClientId(hassUrl));
    final encodedRedirectUri = Uri.encodeComponent(buildRedirectUri(hassUrl));
    final encodedState = Uri.encodeComponent(state);
    return '$hassUrl/auth/authorize?'
        'client_id=$encodedClientId&'
        'redirect_uri=$encodedRedirectUri&'
        'state=$encodedState&'
        'response_type=$responseType';
  }
}
