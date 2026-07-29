// The bulk embed pass: what it writes, what it refuses, and -- above all --
// that it treats a date-disturbing write as a failure rather than a success.
//
// "So long as it doesn't touch the date downloaded of any of the songs" was
// the condition this feature shipped under. Since 2026-07-28 the filesystem
// dates ARE the download dates (re-derived from the manifest library-wide),
// so a write that moved one would be silent damage to the thing this project
// exists to protect.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/artwork_embed_pass.dart';
import 'package:fooplayer_app/artwork/artwork_store.dart';
import 'package:fooplayer_app/artwork/tag_embed_io.dart';
import 'package:fooplayer_app/model/track.dart';

Track _track({
  required String id,
  String relPath = 'song.mp3',
  String artist = 'An Artist',
  String album = 'An Album',
}) => Track(
      contentId: id,
      relPath: relPath,
      rootPath: r'L:\M',
      dateAdded: DateTime.utc(2021, 5, 4),
      title: 'A Title',
      artist: artist,
      album: album,
    );

Uint8List _jpeg() => Uint8List.fromList([0xFF, 0xD8, 0xFF, 1, 2, 3]);

EmbedReport _ok(String path, {bool dates = true}) => EmbedReport(
      path: path,
      outcome: EmbedOutcome.embedded,
      timesPreserved: dates,
    );

void main() {
  late ArtworkStoreRegistry stores;

  setUp(() {
    stores = ArtworkStoreRegistry(appDataDir: Directory.systemTemp);
  });

  test('embeds one file per track, reading each album image only once',
      () async {
    final reads = <String>[];
    final written = <String>[];
    final pass = ArtworkEmbedPass(
      stores: stores,
      readAlbumImage: (root, key) async {
        reads.add(key);
        return _jpeg();
      },
      embed: (file, image) async {
        written.add(file.path);
        return _ok(file.path);
      },
    );

    final report = await pass.run([
      _track(id: 'a', relPath: '1.mp3'),
      _track(id: 'b', relPath: '2.mp3'),
      _track(id: 'c', relPath: '3.flac'),
    ]);

    expect(report.embedded, 3);
    expect(written, hasLength(3));
    expect(reads, hasLength(1),
        reason: 'one album, so the image is fetched once and reused');
    expect(report.datesDisturbed, 0);
  });

  test('a write that disturbed the dates is counted and named, not counted '
      'as a clean success', () async {
    final pass = ArtworkEmbedPass(
      stores: stores,
      readAlbumImage: (_, _) async => _jpeg(),
      embed: (file, image) async =>
          _ok(file.path, dates: !file.path.endsWith('bad.mp3')),
    );

    final report = await pass.run([
      _track(id: 'a', relPath: 'good.mp3'),
      _track(id: 'b', relPath: 'bad.mp3'),
    ]);

    expect(report.embedded, 2);
    expect(report.datesDisturbed, 1);
    expect(report.disturbedPaths.single, endsWith('bad.mp3'));
    expect(report.summary, contains('WITH DATE CHANGES'),
        reason: 'the UI must not report this as an unqualified success');
  });

  test('formats that cannot carry art safely are skipped untouched', () async {
    final written = <String>[];
    final pass = ArtworkEmbedPass(
      stores: stores,
      readAlbumImage: (_, _) async => _jpeg(),
      embed: (file, image) async {
        written.add(file.path);
        return _ok(file.path);
      },
    );

    final report = await pass.run([
      _track(id: 'a', relPath: 'keep.m4a'),
      _track(id: 'b', relPath: 'keep.ogg'),
      _track(id: 'c', relPath: 'fine.mp3'),
    ]);

    expect(report.embedded, 1);
    expect(report.skipped, 2);
    expect(written, hasLength(1), reason: 'the m4a and ogg were never opened');
    expect(report.reasons.keys,
        contains('format cannot carry embedded art'));
  });

  test('an album with no chosen artwork is skipped, not written blank',
      () async {
    var writes = 0;
    final pass = ArtworkEmbedPass(
      stores: stores,
      readAlbumImage: (_, key) async => key.contains('has art') ? _jpeg() : null,
      embed: (file, image) async {
        writes++;
        return _ok(file.path);
      },
    );

    final report = await pass.run([
      _track(id: 'a', album: 'has art'),
      _track(id: 'b', album: 'no art', relPath: '2.mp3'),
    ]);

    expect(report.embedded, 1);
    expect(report.skipped, 1);
    expect(writes, 1);
    expect(report.reasons['no artwork chosen for this album'], 1);
  });

  test('a refusal from the engine is reported with its reason', () async {
    final pass = ArtworkEmbedPass(
      stores: stores,
      readAlbumImage: (_, _) async => _jpeg(),
      embed: (file, image) async => EmbedReport(
        path: file.path,
        outcome: EmbedOutcome.refused,
        reason: 'notMpeg: no MPEG frame sync where the audio should start',
      ),
    );

    final report = await pass.run([_track(id: 'a')]);
    expect(report.embedded, 0);
    expect(report.skipped, 1);
    expect(report.reasons.keys.single, contains('notMpeg'));
  });

  test('a thrown write is caught, counted, and does not stop the pass',
      () async {
    final pass = ArtworkEmbedPass(
      stores: stores,
      readAlbumImage: (_, _) async => _jpeg(),
      embed: (file, image) async {
        if (file.path.endsWith('boom.mp3')) throw const FileSystemException('nope');
        return _ok(file.path);
      },
    );

    final report = await pass.run([
      _track(id: 'a', relPath: 'boom.mp3'),
      _track(id: 'b', relPath: 'after.mp3'),
    ]);

    expect(report.failed, 1);
    expect(report.embedded, 1, reason: 'the pass carried on past the failure');
  });

  test('progress is reported and cancellation stops the pass', () async {
    final seen = <int>[];
    late ArtworkEmbedPass pass;
    pass = ArtworkEmbedPass(
      stores: stores,
      readAlbumImage: (_, _) async => _jpeg(),
      embed: (file, image) async {
        if (seen.length >= 2) pass.cancel();
        return _ok(file.path);
      },
    );

    final report = await pass.run(
      [for (var i = 0; i < 10; i++) _track(id: '$i', relPath: '$i.mp3')],
      onProgress: (done, total) {
        seen.add(done);
        expect(total, 10);
      },
    );

    expect(report.embedded, lessThan(10));
    expect(report.reasons.containsKey('cancelled'), isTrue);
  });

  test('names the tracks it wrote, and only those', () async {
    // The caller corrects the cached "carries embedded art" flag from this
    // list. Re-reading tags library-wide to discover the same thing costs
    // minutes over SMB, and leaving it uncorrected makes a finished pass
    // look like it did nothing.
    final pass = ArtworkEmbedPass(
      stores: stores,
      readAlbumImage: (_, key) async => key.contains('bare') ? null : _jpeg(),
      embed: (file, image) async => file.path.endsWith('3.mp3')
          ? EmbedReport(
              path: file.path,
              outcome: EmbedOutcome.failed,
              reason: 'write failed',
            )
          : _ok(file.path),
    );

    final report = await pass.run([
      _track(id: 'written', relPath: '1.mp3'),
      _track(id: 'no-art', relPath: '2.mp3', album: 'bare'),
      _track(id: 'failed', relPath: '3.mp3'),
      _track(id: 'not-audio', relPath: '4.m4a'),
    ]);

    expect(report.embeddedIds, ['written']);
    expect(report.embedded, 1);
  });
}
