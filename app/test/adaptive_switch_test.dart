// Last modified: 2026-07-24--1837
//
// Pins the Plan 2b adaptive form-factor switch: main.dart's FooPlayerApp
// renders HomeScreen on desktop and PhoneShell on Android, decided by
// usePhoneShell (ui/adaptive.dart) with its injectable isAndroidOverride
// test seam. Also pins the hard desktop guard: a desktop OS never gets the
// phone shell, no matter how narrow the window.
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
  tearDown(() => isAndroidOverride = null);

  testWidgets('desktop (non-Android) renders HomeScreen, not PhoneShell', (
    tester,
  ) async {
    isAndroidOverride = false;
    await tester.pumpWidget(app(fixtureLibrary()));
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(PhoneShell), findsNothing);
  });

  testWidgets('Android renders PhoneShell, not HomeScreen', (tester) async {
    isAndroidOverride = true;
    await tester.pumpWidget(app(fixtureLibrary()));
    expect(find.byType(PhoneShell), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
    // The feed is the phone home view.
    expect(find.text('Newest Song'), findsOneWidget);
  });

  testWidgets(
    'usePhoneShell is false on a desktop OS even at phone-narrow size',
    (tester) async {
      // Tests run on a desktop host (Windows here), so with the Android
      // override off, the Platform.isWindows/... guard must win over the
      // shortestSide < 600 clause -- a narrow desktop window is NOT a phone.
      isAndroidOverride = false;
      late bool result;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: Size(360, 640)),
          child: Builder(
            builder: (context) {
              result = usePhoneShell(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(result, isFalse);
    },
  );
}
