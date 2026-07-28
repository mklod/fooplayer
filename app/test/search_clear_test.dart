import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/library_roots_prefs.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/home_screen.dart';
import 'package:fooplayer_app/ui/layout_prefs.dart';

LibraryModel fixtureLibrary() {
  final m = LibraryModel();
  m.allTracks = [
    Track(
      contentId: 'a',
      relPath: 'a.mp3',
      rootPath: r'L:\Music\RockFolder',
      dateAdded: DateTime.utc(2026, 7, 1),
      title: 'Newest Song',
      artist: 'Muse',
      album: 'X',
      genre: 'Rock',
    ),
    Track(
      contentId: 'b',
      relPath: 'b.mp3',
      rootPath: r'L:\Music\ElectroFolder',
      dateAdded: DateTime.utc(2020, 1, 1),
      title: 'Oldest Song',
      artist: 'Feed Me',
      album: 'Y',
      genre: 'Electronic',
    ),
  ];
  m.status = 'ready';
  return m;
}

Future<void> pumpShell(WidgetTester tester, LibraryModel lib) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: HomeScreen(
        library: lib,
        player: PlayerService(),
        layoutPrefs: LayoutPrefs(),
        libraryRootsPrefs: LibraryRootsPrefs(roots: [], writer: (_) {}),
      ),
    ),
  );
}

void main() {
  final clearButton = find.byKey(const Key('search-clear'));

  testWidgets(
    'typing in search shows the clear (X) button and filters the list',
    (tester) async {
      final lib = fixtureLibrary();
      await pumpShell(tester, lib);

      // No text yet: no clear affordance.
      expect(clearButton, findsNothing);

      await tester.enterText(find.byType(TextField), 'Newest');
      await tester.pumpAndSettle();

      expect(clearButton, findsOneWidget);
      expect(lib.search, 'Newest');
      // List narrowed to the matching track.
      expect(find.text('Newest Song'), findsOneWidget);
      expect(find.text('Oldest Song'), findsNothing);
    },
  );

  testWidgets('clear button uses inkSecondary per AppColors design tokens', (
    tester,
  ) async {
    final lib = fixtureLibrary();
    await pumpShell(tester, lib);
    await tester.enterText(find.byType(TextField), 'x');
    await tester.pumpAndSettle();

    final icon = tester.widget<Icon>(
      find.descendant(of: clearButton, matching: find.byType(Icon)),
    );
    expect(icon.color, AppColors.inkSecondary);
  });

  testWidgets(
    'tapping X clears the field text, restores the full list, and hides X',
    (tester) async {
      final lib = fixtureLibrary();
      await pumpShell(tester, lib);

      await tester.enterText(find.byType(TextField), 'Newest');
      await tester.pumpAndSettle();
      expect(find.text('Oldest Song'), findsNothing); // filtered

      await tester.tap(clearButton);
      await tester.pumpAndSettle();

      // Field text emptied.
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, isEmpty);
      // Library search reset and full list restored.
      expect(lib.search, isEmpty);
      expect(find.text('Newest Song'), findsOneWidget);
      expect(find.text('Oldest Song'), findsOneWidget);
      // Clear affordance gone again.
      expect(clearButton, findsNothing);
    },
  );
}
