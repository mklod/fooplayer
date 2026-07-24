import 'dart:io';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:fooplayer_core/fooplayer_core.dart';

// Dart ignores main's return value, so the exit code must be set explicitly.
Future<void> main(List<String> argv) async {
  exitCode = await _run(argv);
}

Future<int> _run(List<String> argv) async {
  if (argv.isEmpty) {
    stderr.writeln('usage: foolib <status|update|seed> --root <path> [options]');
    return 2;
  }
  final cmd = argv.first;
  final parser = ArgParser()
    ..addOption('root', mandatory: true)
    ..addOption('metadb-json')
    ..addOption('playlists')
    ..addFlag('apply', defaultsTo: false)
    ..addFlag('force', defaultsTo: false);
  late final ArgResults args;
  try {
    args = parser.parse(argv.skip(1).toList());
    // Validate mandatory root by accessing it eagerly
    args['root'];
  } catch (e) {
    stderr.writeln(e.toString());
    stderr.writeln('usage: foolib <status|update|seed> --root <path> [options]');
    return 2;
  }
  final root = Directory(args['root'] as String);
  if (!root.existsSync()) {
    stderr.writeln('root not found: ${root.path}');
    return 2;
  }

  if (!{'status', 'update', 'seed'}.contains(cmd)) {
    stderr.writeln('unknown command: $cmd');
    return 2;
  }

  // Validate everything we can before paying for the (potentially very
  // expensive) full library scan below.
  final manifestFile = File('${root.path}/$manifestFileName');
  String? metadbJson;
  String? playlistsDir;
  if (cmd == 'seed') {
    if (manifestFile.existsSync() && !(args['force'] as bool)) {
      stderr.writeln('manifest already exists — seed refused (use --force to overwrite).');
      return 1;
    }
    metadbJson = args['metadb-json'] as String?;
    if (metadbJson == null) {
      stderr.writeln('seed requires --metadb-json (from tools/export_metadb.py)');
      return 2;
    }
    if (!File(metadbJson).existsSync()) {
      stderr.writeln('metadb file not found: $metadbJson');
      return 2;
    }
    playlistsDir = args['playlists'] as String?;
    if (playlistsDir != null && !Directory(playlistsDir).existsSync()) {
      stderr.writeln('playlists directory not found: $playlistsDir');
      return 2;
    }
  }

  stdout.writeln('scanning ${root.path} ...');
  final scan = await scanLibrary(root, onProgress: (d, t) {
    if (d % 500 == 0 || d == t) stdout.writeln('  $d / $t');
  });
  stdout.writeln('scanned ${scan.length} audio files');

  switch (cmd) {
    case 'status':
      final m = loadManifest(root);
      final d = diffAgainstManifest(m, scan);
      stdout
        ..writeln('manifest tracks : ${m.tracks.length}')
        ..writeln('new tracks      : ${d.newTracks.length}')
        ..writeln('moved/retagged  : ${d.movedOrRetagged.length}')
        ..writeln('missing files   : ${d.missingTrackIds.length}')
        ..writeln('duplicate groups: ${d.duplicates.length}');
      for (final t in d.newTracks.take(20)) {
        stdout.writeln('  new: ${t.relPath}');
      }
      return 0;

    case 'update':
      final m = loadManifest(root);
      final d = diffAgainstManifest(m, scan);
      stdout.writeln(
          'would stamp ${d.newTracks.length} new, update ${d.movedOrRetagged.length} paths');
      if (args['apply'] as bool) {
        applyDiff(m, d, scan, DateTime.now);
        await saveManifest(m, root);
        stdout.writeln('manifest written.');
      } else {
        stdout.writeln('dry run — pass --apply to write.');
      }
      return 0;

    case 'seed':
      final metadb = loadMetadbIndex(metadbJson!);
      final result = buildSeedManifest(
        scan: scan,
        metadb: metadb,
        // FileStat.changed is the creation time on Windows.
        ctimeOf: (rel) =>
            File(p.join(root.path, rel)).statSync().changed.toUtc(),
      );

      final unmatchedTotal = <String, List<String>>{};
      if (playlistsDir != null) {
        final basenameToId = <String, String>{
          for (final t in scan) p.basename(t.relPath).toLowerCase(): t.contentId,
        };
        final txts = Directory(playlistsDir)
            .listSync()
            .whereType<File>()
            .where((f) => p.extension(f.path).toLowerCase() == '.txt');
        for (final f in txts) {
          final r = importTxtPlaylist(
              p.basenameWithoutExtension(f.path), f.readAsLinesSync(), basenameToId);
          result.manifest.playlists.add(r.playlist);
          if (r.unmatched.isNotEmpty) unmatchedTotal[r.playlist.name] = r.unmatched;
        }
      }

      result.report.forEach(stdout.writeln);
      for (final e in unmatchedTotal.entries) {
        stdout.writeln('playlist "${e.key}": ${e.value.length} unmatched lines');
        e.value.take(5).forEach((l) => stdout.writeln('    $l'));
      }
      stdout.writeln('playlists imported: ${result.manifest.playlists.length}');

      if (args['apply'] as bool) {
        await saveManifest(result.manifest, root);
        stdout.writeln('manifest written to ${manifestFile.path}');
      } else {
        stdout.writeln('dry run — pass --apply to write.');
      }
      return 0;

    default:
      // Unreachable: cmd is validated to be one of status/update/seed above.
      throw StateError('unreachable command: $cmd');
  }
}
