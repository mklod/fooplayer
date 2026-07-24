import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'model/library_model.dart';
import 'player/player_service.dart';
import 'ui/app_theme.dart';
import 'ui/home_screen.dart';
import 'ui/layout_prefs.dart';

const _defaultLibraryRoot = r'L:\music (original structure)';

Directory _appDataDir() =>
    Directory(p.join(Platform.environment['APPDATA']!, 'fooplayer'));

File _configFile() => File(p.join(_appDataDir().path, 'config.json'));

/// Reads the whole config.json as a map (empty map if missing/unreadable).
/// Task 3 only cares about the top-level `"ui"` key -- everything else
/// (e.g. `libraryRoot`, and whatever Task 4's `libraryRoots` migration
/// adds later) is read here and written straight back untouched so this
/// stays forward-compatible with the config-schema work in Task 4.
Map<String, dynamic> _loadConfig() {
  final cfg = _configFile();
  try {
    if (cfg.existsSync()) {
      return jsonDecode(cfg.readAsStringSync()) as Map<String, dynamic>;
    }
  } catch (_) {}
  return {};
}

void _writeConfig(Map<String, dynamic> config) {
  final cfg = _configFile();
  cfg.parent.createSync(recursive: true);
  cfg.writeAsStringSync(jsonEncode(config));
}

String _libraryRootFrom(Map<String, dynamic> config) {
  final root = config['libraryRoot'] as String?;
  if (root != null && root.isNotEmpty) return root;
  return _defaultLibraryRoot;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final config = _loadConfig();
  final libraryRootPath = _libraryRootFrom(config);
  if (!config.containsKey('libraryRoot')) {
    // First run (or a config.json missing just this key): seed it, same as
    // the original single-key behavior, without disturbing other keys.
    config['libraryRoot'] = libraryRootPath;
    _writeConfig(config);
  }
  final root = Directory(libraryRootPath);
  final library = LibraryModel();
  final player = PlayerService(libraryRoot: root);
  final layoutPrefs = LayoutPrefs.fromConfig(
    config['ui'] as Map<String, dynamic>?,
    writer: (ui) {
      config['ui'] = ui;
      _writeConfig(config);
    },
  );
  WidgetsBinding.instance.addPostFrameCallback((_) {
    library.load(
      libraryRoot: root,
      cacheFile: File(p.join(_appDataDir().path, 'meta_cache.json')),
    );
  });
  runApp(FooPlayerApp(library: library, player: player, layoutPrefs: layoutPrefs));
}

class FooPlayerApp extends StatelessWidget {
  final LibraryModel library;
  final PlayerService player;
  final LayoutPrefs layoutPrefs;
  const FooPlayerApp({
    super.key,
    required this.library,
    required this.player,
    required this.layoutPrefs,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'fooplayer',
      theme: buildAppTheme(),
      home: HomeScreen(library: library, player: player, layoutPrefs: layoutPrefs),
    );
  }
}
