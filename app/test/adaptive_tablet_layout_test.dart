// A tablet gets the desktop panel layout; a phone gets the compact shell.
//
// "A widescreen tablet is as good as a desktop player" -- so the layout is a
// question about the device, not about the operating system. The rule this
// pins is deliberately orientation-independent: the Galaxy Tab S9+ measures
// 1318x824 logical pixels, so a width-based threshold would have handed it
// the panels in landscape and the compact view in portrait, changing what
// application it appears to be every time it was turned over.
//
// Last modified: 2026-07-29--1630

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/main.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/library_roots_prefs.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/adaptive.dart';
import 'package:fooplayer_app/ui/home_screen.dart';
import 'package:fooplayer_app/ui/layout_prefs.dart';
import 'package:fooplayer_app/ui/phone/phone_shell.dart';

/// Measured on the device: 1752x2800 physical at density 340.
const tabLandscape = Size(1317.6, 824.5);
const tabPortrait = Size(824.5, 1317.6);
// A Pixel-class phone.
const phonePortrait = Size(411.4, 914.3);
const phoneLandscape = Size(914.3, 411.4);

Future<bool> layoutFor(WidgetTester tester, Size size) async {
  late bool result;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: size),
      child: Builder(
        builder: (context) {
          result = useDesktopLayout(context);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return result;
}

LibraryModel fixtureLibrary() {
  final m = LibraryModel();
  m.allTracks = [
    Track(
      contentId: 'a',
      relPath: 'a.mp3',
      dateAdded: DateTime.utc(2026, 7, 1),
      title: 'Newest Song',
      artist: 'Muse',
      album: 'X',
    ),
  ];
  m.status = 'ready';
  return m;
}

Widget app(LibraryModel lib) => FooPlayerApp(
  library: lib,
  player: PlayerService(),
  layoutPrefs: LayoutPrefs(),
  libraryRootsPrefs: LibraryRootsPrefs(roots: [], writer: (_) {}),
);

void main() {
  tearDown(() {
    isAndroidOverride = null;
    isWindowsOverride = null;
  });

  group('breakpoint', () {
    testWidgets('a tablet gets the panel layout in BOTH orientations', (
      tester,
    ) async {
      isAndroidOverride = true;
      expect(await layoutFor(tester, tabLandscape), isTrue);
      expect(
        await layoutFor(tester, tabPortrait),
        isTrue,
        reason: 'turning the tablet over must not change the app',
      );
    });

    testWidgets('a phone gets the compact shell in BOTH orientations', (
      tester,
    ) async {
      isAndroidOverride = true;
      expect(await layoutFor(tester, phonePortrait), isFalse);
      expect(
        await layoutFor(tester, phoneLandscape),
        isFalse,
        reason: 'a phone turned sideways is wider but no taller -- still a '
            'phone, and 411dp of height cannot hold three filter panels',
      );
    });

    testWidgets('a desktop OS keeps the panel layout however narrow', (
      tester,
    ) async {
      // Tests run on Windows here, so with the Android override off the
      // desktop guard must win over any size clause.
      isAndroidOverride = false;
      expect(await layoutFor(tester, const Size(360, 640)), isTrue);
    });
  });

  group('end to end through FooPlayerApp', () {
    testWidgets('tablet-sized Android renders HomeScreen, not PhoneShell', (
      tester,
    ) async {
      isAndroidOverride = true;
      tester.view.physicalSize = const Size(1752, 2800);
      tester.view.devicePixelRatio = 2.125;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(app(fixtureLibrary()));
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(PhoneShell), findsNothing);
    });

    testWidgets('phone-sized Android still renders PhoneShell', (tester) async {
      isAndroidOverride = true;
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(app(fixtureLibrary()));
      expect(find.byType(PhoneShell), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
      expect(find.text('Newest Song'), findsOneWidget);
    });
  });

  group('touch adaptations', () {
    test('"View in folder" is offered only where Explorer exists', () {
      isWindowsOverride = true;
      expect(hasFileExplorer, isTrue);
      isWindowsOverride = false;
      expect(
        hasFileExplorer,
        isFalse,
        reason: 'it shells out to explorer.exe -- on a tablet the menu item '
            'would silently do nothing',
      );
    });
  });
}
