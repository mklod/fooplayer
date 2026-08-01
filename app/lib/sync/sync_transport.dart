// Last modified: 2026-07-31--1727
//
// SyncTransport: the seam between the sync engine and "how bytes actually
// move." LocalDirTransport (dart:io, a plain directory) is the only
// implementation for now -- it's what every sync integration test runs
// against instead of a network. Task 10 adds SmbTransport behind the same
// interface; nothing above this layer should need to change when it lands.
import 'dart:io';

import 'package:fooplayer_core/fooplayer_core.dart' as core;

abstract class SyncTransport {
  /// Cheap reachability check — false must come back fast (a few seconds).
  Future<bool> probe();
  /// Recursive listing under [relDir] ('' = base). Forward-slash relPaths
  /// RELATIVE TO BASE. Directories omitted; dotfiles INCLUDED (sidecars).
  Future<List<core.RemoteFile>> listTree(String relDir);
  /// Whole small file (manifest, playlist json). Null when absent.
  Future<List<int>?> readFile(String relPath);
  /// Atomic-ish remote write: tmp + rename. Creates parent dirs.
  Future<void> writeFile(String relPath, List<int> bytes);
  /// Stream a large file to [local] (creates parent dirs), reporting bytes.
  Future<void> downloadToFile(String relPath, File local,
      {void Function(int got, int total)? onProgress});
  Future<void> deleteRemote(String relPath);
  Future<void> close();
}

/// dart:io implementation of [SyncTransport] over a plain local directory.
/// Used by every sync integration test (and by nothing in production) --
/// point it at a temp dir and exercise the real sync engine with no
/// network involved.
class LocalDirTransport implements SyncTransport {
  final Directory base;
  LocalDirTransport(this.base);

  File _fileFor(String relPath) => File('${base.path}/$relPath');

  @override
  Future<bool> probe() async {
    try {
      if (!await base.exists()) return false;
      await base.list().isEmpty; // listable, not just present
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<core.RemoteFile>> listTree(String relDir) async {
    final root = relDir.isEmpty ? base : Directory('${base.path}/$relDir');
    if (!await root.exists()) return [];
    final baseLen = base.path.length;
    final out = <core.RemoteFile>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relPath = entity.path
          .substring(baseLen)
          .replaceAll('\\', '/')
          .replaceFirst(RegExp(r'^/'), '');
      final stat = await entity.stat();
      out.add(core.RemoteFile(
        relPath: relPath,
        size: stat.size,
        mtimeMs: stat.modified.millisecondsSinceEpoch,
      ));
    }
    return out;
  }

  @override
  Future<List<int>?> readFile(String relPath) async {
    final f = _fileFor(relPath);
    if (!await f.exists()) return null;
    return f.readAsBytes();
  }

  @override
  Future<void> writeFile(String relPath, List<int> bytes) async {
    final target = _fileFor(relPath);
    await target.parent.create(recursive: true);
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(bytes);
    if (await target.exists()) await target.delete(); // Windows rename won't overwrite
    await tmp.rename(target.path);
  }

  @override
  Future<void> downloadToFile(String relPath, File local,
      {void Function(int got, int total)? onProgress}) async {
    final source = _fileFor(relPath);
    final total = await source.length();
    await local.parent.create(recursive: true);
    var got = 0;
    final sink = local.openWrite();
    try {
      await for (final chunk in source.openRead()) {
        sink.add(chunk);
        got += chunk.length;
        onProgress?.call(got, total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    // Always fire a final (total, total) call -- including 0-byte files,
    // where the loop above never runs and `got` is already `total`.
    onProgress?.call(total, total);
  }

  @override
  Future<void> deleteRemote(String relPath) async {
    final f = _fileFor(relPath);
    if (await f.exists()) await f.delete();
  }

  @override
  Future<void> close() async {}
}
