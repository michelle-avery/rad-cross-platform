import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppStateProvider extends ChangeNotifier {
  bool _isConfigured = false;
  String? _homeAssistantUrl;

  bool get isConfigured => _isConfigured;
  String? get homeAssistantUrl => _homeAssistantUrl;

  AppStateProvider() {
    _loadSavedState();
  }

  Future<void> _loadSavedState() async {
    final prefs = await SharedPreferences.getInstance();
    _homeAssistantUrl = prefs.getString('home_assistant_url');
    _isConfigured = _homeAssistantUrl != null && _homeAssistantUrl!.isNotEmpty;
    notifyListeners();
  }

  Future<void> setHomeAssistantUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    _homeAssistantUrl = url;
    _isConfigured = true;
    await prefs.setString('home_assistant_url', url);
    notifyListeners();
  }

  Future<void> resetConfiguration() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('home_assistant_url');
    _homeAssistantUrl = null;
    _isConfigured = false;
    notifyListeners();
  }
}
