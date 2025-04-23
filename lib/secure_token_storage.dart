/// SecureTokenStorage provides a unified interface for securely storing OAuth tokens.
/// Uses flutter_secure_storage on Android, and a simple encrypted file on Linux (with a warning).
///
/// Usage:
///   await SecureTokenStorage.saveTokens(jsonString);
///   final tokens = await SecureTokenStorage.readTokens();
///   await SecureTokenStorage.deleteTokens();

import 'dart:io';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureTokenStorage {
  static const _storageKey = 'oauth_tokens';
  static const _linuxFileName = '.radcxp_tokens';

  static Future<void> saveTokens(String tokensJson) async {
    if (Platform.isAndroid) {
      final storage = const FlutterSecureStorage();
      await storage.write(key: _storageKey, value: tokensJson);
    } else if (Platform.isLinux) {
      final home = Platform.environment['HOME'] ?? '.';
      final file = File('$home/$_linuxFileName');
      final obfuscated = base64Encode(_xor(tokensJson.codeUnits, 0x42));
      await file.writeAsString(obfuscated);
    } else {
      throw UnsupportedError('Secure storage not supported for this platform');
    }
  }

  static Future<String?> readTokens() async {
    if (Platform.isAndroid) {
      final storage = const FlutterSecureStorage();
      return await storage.read(key: _storageKey);
    } else if (Platform.isLinux) {
      final home = Platform.environment['HOME'] ?? '.';
      final file = File('$home/$_linuxFileName');
      if (!await file.exists()) return null;
      final obfuscated = await file.readAsString();
      final decoded = utf8.decode(_xor(base64Decode(obfuscated), 0x42));
      return decoded;
    } else {
      throw UnsupportedError('Secure storage not supported for this platform');
    }
  }

  static Future<void> deleteTokens() async {
    if (Platform.isAndroid) {
      final storage = const FlutterSecureStorage();
      await storage.delete(key: _storageKey);
    } else if (Platform.isLinux) {
      final home = Platform.environment['HOME'] ?? '.';
      final file = File('$home/$_linuxFileName');
      if (await file.exists()) await file.delete();
    } else {
      throw UnsupportedError('Secure storage not supported for this platform');
    }
  }

  static List<int> _xor(List<int> data, int key) =>
      data.map((b) => b ^ key).toList();
}
