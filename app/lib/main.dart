import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'model/library_model.dart';
import 'player/player_service.dart';
import 'ui/home_screen.dart';

const _defaultLibraryRoot = r'L:\music (original structure)';

Directory _appDataDir() =>
    Directory(p.join(Platform.environment['APPDATA']!, 'fooplayer'));

String _loadLibraryRoot() {
  final cfg = File(p.join(_appDataDir().path, 'config.json'));
  try {
    if (cfg.existsSync()) {
      final j = jsonDecode(cfg.readAsStringSync()) as Map<String, dynamic>;
      final root = j['libraryRoot'] as String?;
      if (root != null && root.isNotEmpty) return root;
    }
  } catch (_) {}
  cfg.parent.createSync(recursive: true);
  cfg.writeAsStringSync(jsonEncode({'libraryRoot': _defaultLibraryRoot}));
  return _defaultLibraryRoot;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final root = Directory(_loadLibraryRoot());
  final library = LibraryModel();
  final player = PlayerService(libraryRoot: root);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    library.load(
      libraryRoot: root,
      cacheFile: File(p.join(_appDataDir().path, 'meta_cache.json')),
    );
  });
  runApp(FooPlayerApp(library: library, player: player));
}

class FooPlayerApp extends StatelessWidget {
  final LibraryModel library;
  final PlayerService player;
  const FooPlayerApp({super.key, required this.library, required this.player});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'fooplayer',
      theme: ThemeData.dark(useMaterial3: true),
      home: HomeScreen(library: library, player: player),
    );
  }
}
