// The sidebar's "Embed art in files" action.
//
// It rewrites files in the music library, so it asks first, and the dialog
// has to say what it will and will not touch -- in particular that the date
// downloaded is safe, which was the condition the feature shipped under.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/artwork_store.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/library_roots_prefs.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/home_screen.dart';
import 'package:fooplayer_app/ui/layout_prefs.dart';

LibraryModel _library() => LibraryModel()
  ..allTracks = [
    Track(
      contentId: 'a',
      relPath: 'one.mp3',
      rootPath: r'L:\M',
      dateAdded: DateTime.utc(2022, 3, 3),
      title: 'One',
      artist: 'Artist',
      album: 'Album',
    ),
    Track(
      contentId: 'b',
      relPath: 'two.flac',
      rootPath: r'L:\M',
      dateAdded: DateTime.utc(2022, 3, 4),
      title: 'Two',
      artist: 'Artist',
      album: 'Album',
    ),
    // Not embeddable -- must not be counted in the dialog's total.
    Track(
      contentId: 'c',
      relPath: 'three.m4a',
      rootPath: r'L:\M',
      dateAdded: DateTime.utc(2022, 3, 5),
      title: 'Three',
      artist: 'Artist',
      album: 'Album',
    ),
  ]
  ..status = 'ready';

Future<void> _pump(WidgetTester tester, {ArtworkStoreRegistry? stores}) async {
  await tester.binding.setSurfaceSize(const Size(1400, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: HomeScreen(
        library: _library(),
        player: PlayerService(),
        layoutPrefs: LayoutPrefs(),
        libraryRootsPrefs: LibraryRootsPrefs(roots: [], writer: (_) {}),
        artworkStores: stores,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the action is hidden when no artwork sidecars are wired',
      (tester) async {
    await _pump(tester);
    expect(find.byKey(const Key('embed-artwork')), findsNothing);
  });

  testWidgets('it confirms before writing, and says what it protects',
      (tester) async {
    await _pump(
      tester,
      stores: ArtworkStoreRegistry(appDataDir: Directory.systemTemp),
    );

    expect(find.byKey(const Key('embed-artwork')), findsOneWidget);
    await tester.tap(find.byKey(const Key('embed-artwork')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('embed-artwork-confirm')), findsOneWidget);

    final body = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byKey(const Key('embed-artwork-confirm')),
            matching: find.byType(Text),
          ),
        )
        .map((t) => t.data ?? '')
        .join(' ');

    expect(body, contains('2 eligible tracks'),
        reason: 'the .m4a is excluded -- embedding in one would change its '
            'content ID, and with it the date-added');
    expect(body, contains('date downloaded is not touched'));
    expect(body, contains('Audio is never rewritten'));
  });

  testWidgets('cancelling writes nothing', (tester) async {
    await _pump(
      tester,
      stores: ArtworkStoreRegistry(appDataDir: Directory.systemTemp),
    );
    await tester.tap(find.byKey(const Key('embed-artwork')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('embed-artwork-confirm')), findsNothing);
    // No pass started, so no progress status was ever set.
    expect(find.textContaining('embedding art'), findsNothing);
  });
}
