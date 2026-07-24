import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'model/app_config.dart';
import 'model/library_model.dart';
import 'model/library_roots_prefs.dart';
import 'player/player_service.dart';
import 'ui/app_theme.dart';
import 'ui/home_screen.dart';
import 'ui/layout_prefs.dart';

const _defaultLibraryRoot = r'L:\music (original structure)';

Directory _appDataDir() =>
    Directory(p.join(Platform.environment['APPDATA']!, 'fooplayer'));

File _configFile() => File(p.join(_appDataDir().path, 'config.json'));

/// Reads the whole config.json as a map (empty map if missing; see
/// [readConfigFile] for the corrupt-file handling). Every key this app
/// doesn't otherwise interpret is preserved so it round-trips through
/// [_writeConfig] untouched.
Map<String, dynamic> _loadConfig() => readConfigFile(_configFile());

void _writeConfig(Map<String, dynamic> config) {
  final cfg = _configFile();
  cfg.parent.createSync(recursive: true);
  cfg.writeAsStringSync(jsonEncode(config));
}

/// Flushes any debounced [LayoutPrefs] write on app shutdown so a
/// drag-a-divider-then-close-the-window sequence isn't silently lost.
///
/// Two hooks are wired for reliability, since desktop shutdown paths vary
/// by platform/embedder version:
///
/// - [AppLifecycleListener.onExitRequested] is the modern, awaitable
///   exit-request flow -- on Windows the engine's WindowsLifecycleManager
///   intercepts WM_CLOSE on the last window, asks the framework via this
///   callback whether it's OK to exit, and only re-dispatches the real
///   close (and lets the process actually terminate) after the returned
///   future completes. This reliably runs our flush *before* the process
///   goes away, which is exactly the guarantee needed here.
/// - [WidgetsBindingObserver.didChangeAppLifecycleState]'s
///   [AppLifecycleState.detached] transition is wired too, as a
///   defense-in-depth fallback for any shutdown path that bypasses the
///   exit-request flow (e.g. a future/alternate embedder, or a runner
///   without the WM_CLOSE-interception plumbing).
class _LifecycleFlusher with WidgetsBindingObserver {
  final LayoutPrefs layoutPrefs;

  _LifecycleFlusher(this.layoutPrefs) {
    WidgetsBinding.instance.addObserver(this);
    AppLifecycleListener(
      onExitRequested: () async {
        layoutPrefs.flush();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      layoutPrefs.flush();
    }
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final rawConfig = _loadConfig();
  final appConfig = migrateConfig(rawConfig, defaultRoot: _defaultLibraryRoot);
  // `config` (appConfig.raw) is the single mutable map every writer below
  // reads from and persists via _writeConfig -- it already carries the
  // migrated `libraryRoots` plus every other preserved key (e.g. `"ui"`).
  final config = appConfig.raw;
  if (needsMigrationWrite(rawConfig)) {
    _writeConfig(config);
  }

  final library = LibraryModel();
  final player = PlayerService();

  final layoutPrefs = LayoutPrefs.fromConfig(
    config['ui'] as Map<String, dynamic>?,
    writer: (ui) {
      config['ui'] = ui;
      _writeConfig(config);
    },
  );

  final cacheFile = File(p.join(_appDataDir().path, 'meta_cache.json'));
  final libraryRootsPrefs = LibraryRootsPrefs(
    roots: appConfig.libraryRoots,
    writer: (roots) {
      config['libraryRoots'] = roots;
      _writeConfig(config);
    },
  );
  void reloadLibrary() {
    library.load(
      libraryRoots: libraryRootsPrefs.roots.map(Directory.new).toList(),
      cacheFile: cacheFile,
    );
  }

  // Settings-dialog add/remove calls writer() above then notifies -- react
  // by reloading so the merged feed/playlists reflect the new root set.
  libraryRootsPrefs.addListener(reloadLibrary);

  _LifecycleFlusher(layoutPrefs);
  WidgetsBinding.instance.addPostFrameCallback((_) => reloadLibrary());
  runApp(FooPlayerApp(
    library: library,
    player: player,
    layoutPrefs: layoutPrefs,
    libraryRootsPrefs: libraryRootsPrefs,
  ));
}

class FooPlayerApp extends StatelessWidget {
  final LibraryModel library;
  final PlayerService player;
  final LayoutPrefs layoutPrefs;
  final LibraryRootsPrefs libraryRootsPrefs;
  const FooPlayerApp({
    super.key,
    required this.library,
    required this.player,
    required this.layoutPrefs,
    required this.libraryRootsPrefs,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'fooplayer',
      theme: buildAppTheme(),
      home: HomeScreen(
        library: library,
        player: player,
        layoutPrefs: layoutPrefs,
        libraryRootsPrefs: libraryRootsPrefs,
      ),
    );
  }
}
