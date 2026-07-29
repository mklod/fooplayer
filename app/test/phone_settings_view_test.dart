// Last modified: 2026-07-24--1855
//
// Widget tests for the phone Settings page (Plan 2b: the drawer's Settings
// destination "reuses existing SettingsDialog content as a page"): the
// shared LibraryRootsEditor rendered live against a real LibraryRootsPrefs
// (writer spied, so no config.json is touched) -- roots listed by full
// path, add via the injected picker, remove via the per-root button, and
// the manifest-health notes from LibraryModel. Also pins the shell wiring
// shape: mounted via viewBuilders[PhoneView.settings], no "coming soon"
// placeholder anywhere.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/library_roots_prefs.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/phone/phone_settings_view.dart';
import 'package:fooplayer_app/ui/phone/phone_shell.dart';

LibraryModel fixtureLibrary() {
  final m = LibraryModel();
  m.status = 'ready';
  return m;
}

Future<void> pumpSettings(
  WidgetTester tester, {
  required LibraryModel library,
  required LibraryRootsPrefs prefs,
  Future<String?> Function()? pickDirectory,
}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: PhoneSettingsView(
          library: library,
          libraryRootsPrefs: prefs,
          pickDirectory: pickDirectory ?? () async => null,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('lists the configured roots by full path', (tester) async {
    final prefs = LibraryRootsPrefs(
      roots: [r'C:\music', r'D:\more music'],
      writer: (_) {},
    );
    await pumpSettings(tester, library: fixtureLibrary(), prefs: prefs);

    expect(find.text('Library roots'), findsOneWidget);
    expect(find.text(r'C:\music'), findsOneWidget);
    expect(find.text(r'D:\more music'), findsOneWidget);
  });

  testWidgets(
    'Add folder... goes through the picker into prefs and the new root '
    'appears live (prefs listener rebuild)',
    (tester) async {
      final written = <List<String>>[];
      final prefs = LibraryRootsPrefs(
        roots: [r'C:\music'],
        writer: written.add,
      );
      await pumpSettings(
        tester,
        library: fixtureLibrary(),
        prefs: prefs,
        pickDirectory: () async => r'E:\picked folder',
      );

      await tester.tap(find.byKey(const Key('add-folder-button')));
      await tester.pumpAndSettle();

      expect(prefs.roots, [r'C:\music', r'E:\picked folder']);
      expect(written, [
        [r'C:\music', r'E:\picked folder'],
      ]);
      // The page listens to prefs, so the tile appears without a reopen.
      expect(find.text(r'E:\picked folder'), findsOneWidget);
    },
  );

  testWidgets('removing a root updates prefs and the tile disappears', (
    tester,
  ) async {
    final prefs = LibraryRootsPrefs(
      roots: [r'C:\music', r'D:\more music'],
      writer: (_) {},
    );
    await pumpSettings(tester, library: fixtureLibrary(), prefs: prefs);

    await tester.tap(find.byKey(const Key('remove-root-D:\\more music')));
    await tester.pumpAndSettle();

    expect(prefs.roots, [r'C:\music']);
    expect(find.text(r'D:\more music'), findsNothing);
    expect(find.text(r'C:\music'), findsOneWidget);
  });

  testWidgets('a folder that is not set up says so, and offers to do it', (
    tester,
  ) async {
    final library = fixtureLibrary();
    library.rootsMissingManifest = [r'C:\new drop'];
    final prefs = LibraryRootsPrefs(
      roots: [r'C:\music', r'C:\new drop'],
      writer: (_) {},
    );
    await pumpSettings(tester, library: library, prefs: prefs);

    // "seed with foolib" was a dead end on a phone: there is no CLI to run,
    // so adding a music folder just showed nothing, forever.
    expect(
      find.descendant(
        of: find.byKey(const Key('root-tile-C:\\new drop')),
        matching: find.text('not set up yet — tap Set up to scan it'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('setup-root-C:\\new drop')), findsOneWidget);
    expect(
      find.byKey(const Key('setup-root-C:\\music')),
      findsNothing,
      reason: 'a root that is already set up needs no button',
    );
  });

  testWidgets('drawer Settings entry shows the real page when wired via '
      'viewBuilders (production shape) -- no "coming soon"', (tester) async {
    final library = fixtureLibrary();
    final prefs = LibraryRootsPrefs(roots: [r'C:\music'], writer: (_) {});
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: PhoneShell(
          library: library,
          player: PlayerService(),
          onPlayTrack: (_, _) {},
          onTrackLongPress: (_, _) {},
          viewBuilders: {
            PhoneView.settings: (_) => PhoneSettingsView(
              library: library,
              libraryRootsPrefs: prefs,
              pickDirectory: () async => null,
            ),
          },
        ),
      ),
    );

    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('phone-drawer-settings')));
    await tester.pumpAndSettle();

    expect(find.text('coming soon'), findsNothing);
    expect(find.text('Library roots'), findsOneWidget);
    expect(find.text(r'C:\music'), findsOneWidget);
    expect(find.byKey(const Key('add-folder-button')), findsOneWidget);
  });
}
