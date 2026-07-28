// ignore_for_file: avoid_print -- diagnostic CLI, output IS the point
// Reads the embed-test folder back through the app's OWN metadata reader and
// player, so "it works" means the app agrees -- not just ffprobe.
// Usage: dart run tool/embed_verify.dart <folder>
import 'dart:io';

import 'package:fooplayer_app/metadata/tags.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  MediaKit.ensureInitialized();
  final dir = Directory(args[0]);
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => const {'.mp3', '.m4a', '.flac'}
          .contains(p.extension(f.path).toLowerCase()))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final f in files) {
    final name = p.basename(f.path);
    final tags = await readTags(f);
    final art = await readArtSafe(f);

    final player = Player();
    await player.setVolume(0);
    final errors = <String>{};
    player.stream.error.listen(errors.add);
    Duration dur = Duration.zero;
    player.stream.duration.listen((d) => dur = d);
    Duration pos = Duration.zero;
    player.stream.position.listen((d) => pos = d);
    try {
      await player.open(Media(f.path));
      await Future<void>.delayed(const Duration(seconds: 3));
    } catch (e) {
      errors.add('open threw: $e');
    }
    await player.dispose();

    print(name);
    print('  app tags : "${tags.title}" / "${tags.artist}" / "${tags.album}"'
        '  ${tags.durationMs}ms');
    print('  app art  : ${art == null ? "none" : "${art.length} bytes"}');
    print('  playback : duration=$dur played=$pos '
        'errors=${errors.isEmpty ? "none" : errors.join("|")}');
    print('');
  }
  exit(0);
}
