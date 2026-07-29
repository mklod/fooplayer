// In-app tag editing.
//
// The feature exists because the only other way to fix a wrong tag was
// Mp3tag, which is what destroyed every download date in this library and
// started the project. So the tests that matter are the ones about restraint:
// a field you didn't touch must not be written, a file the engine refuses
// must not be reported as updated, and a write that lost a date must be
// called out rather than folded into a success count.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/tag_embed.dart';
import 'package:fooplayer_app/artwork/tag_embed_io.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/edit_tags_action.dart';
import 'package:fooplayer_app/ui/edit_tags_dialog.dart';

Track _track(
  String id, {
  String title = 'A Title',
  String artist = 'An Artist',
  String album = 'An Album',
  String genre = '',
  int? trackNumber,
}) => Track(
  contentId: id,
  relPath: '$id.mp3',
  rootPath: r'L:\M',
  dateAdded: DateTime.utc(2020),
  title: title,
  artist: artist,
  album: album,
  genre: genre,
  trackNumber: trackNumber,
);

/// Opens the dialog and returns what Save produced.
Future<TagEdits?> _runDialog(
  WidgetTester tester,
  List<Track> tracks, {
  Map<String, String> type = const {},
  void Function()? beforeSave,
}) async {
  TagEdits? result;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async => result = await showDialog<TagEdits>(
              context: context,
              builder: (_) => EditTagsDialog(tracks: tracks),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  for (final entry in type.entries) {
    await tester.enterText(
      find.byKey(Key('edit-tags-${entry.key}')),
      entry.value,
    );
  }
  beforeSave?.call();
  await tester.tap(find.byKey(const Key('edit-tags-save')));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  group('the dialog', () {
    testWidgets('an untouched field is not written', (tester) async {
      final edits = await _runDialog(tester, [_track('a')]);
      expect(
        edits!.isEmpty,
        isTrue,
        reason: 'opening and saving must not rewrite every frame',
      );
    });

    testWidgets('only the field you changed is written', (tester) async {
      final edits = await _runDialog(
        tester,
        [_track('a')],
        type: {'artist': 'Corrected'},
      );
      expect(edits!.artist, 'Corrected');
      expect(edits.title, isNull);
      expect(edits.album, isNull);
    });

    testWidgets('a field the selection disagrees on shows (various) and is '
        'left alone', (tester) async {
      final edits = await _runDialog(tester, [
        _track('a', title: 'One', album: 'Shared'),
        _track('b', title: 'Two', album: 'Shared'),
      ], type: {'genre': 'Rock'},
          // The hint only exists while the dialog is open.
          beforeSave: () => expect(find.text('(various)'), findsOneWidget));

      expect(
        edits!.title,
        isNull,
        reason: 'each track keeps its own title',
      );
      expect(edits.genre, 'Rock');
    });

    testWidgets('typing over (various) writes it to all of them', (
      tester,
    ) async {
      final edits = await _runDialog(tester, [
        _track('a', album: 'Wrong One'),
        _track('b', album: 'Wrong Two'),
      ], type: {'album': 'The Right One'});
      expect(edits!.album, 'The Right One');
    });

    testWidgets('clearing a shared field clears it on disk', (tester) async {
      final edits = await _runDialog(
        tester,
        [_track('a', album: '2012-11')],
        type: {'album': ''},
      );
      expect(edits!.album, '', reason: 'empty means clear, not "unchanged"');
    });

    testWidgets('cancel writes nothing', (tester) async {
      TagEdits? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async => result = await showDialog<TagEdits>(
                  context: context,
                  builder: (_) => EditTagsDialog(tracks: [_track('a')]),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(result, isNull);
    });
  });

  group('applying the edit', () {
    /// Drives editTrackTags with a fake writer and returns the SnackBar text.
    Future<String> run(
      WidgetTester tester,
      List<Track> tracks,
      TagWriter writer, {
      LibraryModel? library,
    }) async {
      final model = library ?? (LibraryModel()..allTracks = tracks);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => editTrackTags(
                  context: context,
                  messenger: ScaffoldMessenger.of(context),
                  tracks: tracks,
                  library: model,
                  writer: writer,
                ),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('edit-tags-artist')),
        'Fixed',
      );
      await tester.tap(find.byKey(const Key('edit-tags-save')));
      await tester.pumpAndSettle();
      return tester.widget<Text>(find.byType(SnackBar).evaluate().isEmpty
              ? find.text('nothing')
              : find.descendant(
                  of: find.byType(SnackBar),
                  matching: find.byType(Text),
                ))
          .data!;
    }

    testWidgets('reports what was written', (tester) async {
      final text = await run(
        tester,
        [_track('a'), _track('b')],
        (file, edits) async =>
            EmbedReport(path: file.path, outcome: EmbedOutcome.embedded),
      );
      expect(text, contains('2 updated'));
    });

    testWidgets('a refused file is not counted as updated', (tester) async {
      final text = await run(
        tester,
        [_track('a')],
        (file, edits) async => EmbedReport(
          path: file.path,
          outcome: EmbedOutcome.refused,
          reason: 'FLAC tag editing is not implemented yet',
        ),
      );
      expect(text, contains('1 skipped'));
      expect(text, contains('FLAC'));
      expect(text, isNot(contains('updated')));
    });

    testWidgets('a lost date is shouted about, not folded into a total', (
      tester,
    ) async {
      final text = await run(
        tester,
        [_track('a')],
        (file, edits) async => EmbedReport(
          path: file.path,
          outcome: EmbedOutcome.embedded,
          timesPreserved: false,
        ),
      );
      expect(text, contains('WITH DATE CHANGES'));
    });

    testWidgets('a thrown writer does not take the others down', (
      tester,
    ) async {
      final text = await run(
        tester,
        [_track('a'), _track('b')],
        (file, edits) async {
          if (file.path.endsWith('a.mp3')) throw const FileSystemException('x');
          return EmbedReport(path: file.path, outcome: EmbedOutcome.embedded);
        },
      );
      expect(text, contains('1 updated'));
      expect(text, contains('1 failed'));
    });

    testWidgets('only the files that took the edit have their cache updated', (
      tester,
    ) async {
      final tracks = [_track('a'), _track('b')];
      final model = LibraryModel()..allTracks = tracks;
      await run(
        tester,
        tracks,
        (file, edits) async => file.path.endsWith('a.mp3')
            ? EmbedReport(path: file.path, outcome: EmbedOutcome.embedded)
            : EmbedReport(
                path: file.path,
                outcome: EmbedOutcome.refused,
                reason: 'nope',
              ),
        library: model,
      );

      final byId = {for (final t in model.allTracks) t.contentId: t};
      expect(byId['a']!.artist, 'Fixed');
      expect(
        byId['b']!.artist,
        'An Artist',
        reason: 'the refused file still shows what it really contains',
      );
    });
  });
}
