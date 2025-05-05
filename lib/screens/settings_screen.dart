import 'dart:io';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/app_state_provider.dart';
import 'log_viewer_screen.dart';

final _log = Logger('SettingsScreen');
const String _logLevelPrefKey = 'logLevel';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Level _selectedLevel = Level.INFO;
  bool _isLoading = true;

  final List<Level> _logLevels = [
    Level.ALL,
    Level.FINEST,
    Level.FINER,
    Level.FINE,
    Level.CONFIG,
    Level.INFO,
    Level.WARNING,
    Level.SEVERE,
    Level.SHOUT,
    Level.OFF,
  ];

  @override
  void initState() {
    super.initState();
    _loadLogLevelPreference();
  }

  Future<void> _loadLogLevelPreference() async {
    setState(() {
      _isLoading = true;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedLevelName = prefs.getString(_logLevelPrefKey);
      if (savedLevelName != null) {
        final foundLevel = _logLevels.firstWhere(
          (level) => level.name == savedLevelName,
          orElse: () {
            _log.warning(
                'Saved log level "$savedLevelName" not found in options, defaulting to INFO.');
            return Level.INFO;
          },
        );
        _selectedLevel = foundLevel;
        Logger.root.level = _selectedLevel;
        _log.info('Loaded log level preference: ${_selectedLevel.name}');
      } else {
        _log.info(
            'No log level preference found, using default: ${_selectedLevel.name}');
        Logger.root.level = _selectedLevel;
      }
    } catch (e, s) {
      _log.severe('Error loading log level preference: $e', e, s);
      Logger.root.level = _selectedLevel;
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _updateLogLevelPreference(Level newLevel) async {
    if (_selectedLevel == newLevel) return;

    setState(() {
      _selectedLevel = newLevel;
    });

    Logger.root.level = newLevel;
    _log.info('Log level updated live to: ${newLevel.name}');

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_logLevelPrefKey, newLevel.name);
      _log.info('Saved log level preference: ${newLevel.name}');
    } catch (e, s) {
      _log.severe('Error saving log level preference: $e', e, s);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Consumer<AppStateProvider>(
              builder: (context, appState, child) {
                return ListView(
                  padding: const EdgeInsets.all(16.0),
                  children: <Widget>[
                    ListTile(
                      title: const Text('Home Assistant URL'),
                      subtitle: Text(appState.homeAssistantUrl ?? 'Not Set'),
                      leading: const Icon(Icons.link),
                    ),
                    ListTile(
                      title: const Text('Device ID'),
                      subtitle: Text(appState.deviceId ?? 'Not Set'),
                      leading: const Icon(Icons.perm_device_information),
                    ),
                    ListTile(
                      title: const Text('App Version'),
                      subtitle: Text(appState.appVersion ?? 'Unknown'),
                      leading: const Icon(Icons.info_outline),
                    ),
                    const Divider(),
                    ListTile(
                      title: const Text('Hide Header (Server Setting)'),
                      subtitle:
                          Text(appState.hideHeader ? 'Enabled' : 'Disabled'),
                      leading: const Icon(Icons.view_agenda_outlined),
                    ),
                    ListTile(
                      title: const Text('Hide Sidebar (Server Setting)'),
                      subtitle:
                          Text(appState.hideSidebar ? 'Enabled' : 'Disabled'),
                      leading: const Icon(Icons.view_sidebar_outlined),
                    ),
                    const Divider(),
                    ListTile(
                      title: const Text('Logging Level'),
                      subtitle: const Text(
                          'Controls the verbosity of application logs.'),
                      trailing: DropdownButton<Level>(
                        value: _selectedLevel,
                        onChanged: (Level? newValue) {
                          if (newValue != null) {
                            _updateLogLevelPreference(newValue);
                          }
                        },
                        items: _logLevels
                            .map<DropdownMenuItem<Level>>((Level level) {
                          return DropdownMenuItem<Level>(
                            value: level,
                            child: Text(level.name),
                          );
                        }).toList(),
                      ),
                    ),
                    const Divider(),
                    if (Platform.isAndroid)
                      ListTile(
                        title: const Text('View Logs'),
                        leading: const Icon(Icons.description),
                        onTap: () {
                          Navigator.of(context).push(MaterialPageRoute(
                            builder: (context) => const LogViewerScreen(),
                          ));
                        },
                      ),
                  ],
                );
              },
            ),
    );
  }
}
