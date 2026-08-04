// Last modified: 2026-08-04--0131
//
// Widget tests for the Plan 2b PhoneShell: drawer navigation + active
// highlight, the feed view's newest-first rows (title / artist — album /
// duration), tap-plays-immediately (phone idiom), long-press opening the
// real context sheet through the injected callback, and the wiring slots
// (miniPlayerBuilder / activity / viewBuilders) main.dart fills.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/activity_model.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/playlist_store.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/phone/phone_shell.dart';
import 'package:fooplayer_app/ui/phone/track_context_sheet.dart';

LibraryModel fixtureLibrary() {
  final m = LibraryModel();
  m.allTracks = [
    Track(
      contentId: 'old',
      relPath: 'old.mp3',
      dateAdded: DateTime.utc(2020, 1, 1),
      title: 'Oldest Song',
      artist: 'Feed Me',
      album: 'Calamari Tuesday',
      durationMs: 200000,
    ),
    Track(
      contentId: 'new',
      relPath: 'new.mp3',
      dateAdded: DateTime.utc(2026, 7, 1),
      title: 'Newest Song',
      artist: 'Muse',
      album: 'Absolution',
    ),
  ];
  m.status = 'ready';
  return m;
}

Future<void> pumpShell(
  WidgetTester tester, {
  required LibraryModel library,
  void Function(List<Track>, int)? onPlayTrack,
  void Function(BuildContext, Track)? onTrackLongPress,
  WidgetBuilder? miniPlayerBuilder,
  ActivityModel? activity,
  Map<PhoneView, WidgetBuilder> viewBuilders = const {},
}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: PhoneShell(
        library: library,
        player: PlayerService(),
        // Every test injects a spy (or discards) -- the default would build
        // a real media_kit Player, which has no natives under `flutter test`.
        onPlayTrack: onPlayTrack ?? (_, _) {},
        onTrackLongPress: onTrackLongPress ?? (_, _) {},
        miniPlayerBuilder: miniPlayerBuilder,
        activity: activity,
        viewBuilders: viewBuilders,
      ),
    ),
  );
}

Future<void> openDrawer(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Open navigation menu'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('feed shows rows newest-first with subtitle and duration', (
    tester,
  ) async {
    await pumpShell(tester, library: fixtureLibrary());
    expect(find.text('Newest Song'), findsOneWidget);
    expect(find.text('Oldest Song'), findsOneWidget);
    // Newest above oldest (date-added desc).
    expect(
      tester.getTopLeft(find.text('Newest Song')).dy,
      lessThan(tester.getTopLeft(find.text('Oldest Song')).dy),
    );
    // Subtitle format: artist — album.
    expect(find.text('Muse — Absolution'), findsOneWidget);
    // Duration right cell: 200000 ms = 3:20; the duration-less track shows
    // an empty cell (no fake 0:00 anywhere).
    expect(find.text('3:20'), findsOneWidget);
    expect(find.text('0:00'), findsNothing);
    // AppBar titles the active view.
    expect(find.text('Library'), findsOneWidget);
  });

  testWidgets('tapping a feed row plays it via the injected callback', (
    tester,
  ) async {
    final played = <(List<Track>, int)>[];
    await pumpShell(
      tester,
      library: fixtureLibrary(),
      onPlayTrack: (tracks, index) => played.add((tracks, index)),
    );
    await tester.tap(find.text('Oldest Song'));
    await tester.pump();
    expect(played, hasLength(1));
    final (queue, index) = played.single;
    // The queue is the feed in its on-screen (date-desc) order and the
    // index points at the tapped row.
    expect(queue.map((t) => t.title).toList(), ['Newest Song', 'Oldest Song']);
    expect(index, 1);
  });

  testWidgets('long-press on a feed row opens the real context sheet with both '
      'plan actions (Add to playlist / View details)', (tester) async {
    final library = fixtureLibrary();
    final store = PlaylistStore(library: library, device: 'test');
    // Production-shaped wiring (main.dart closes the real sheet over the
    // library + store exactly like this).
    await pumpShell(
      tester,
      library: library,
      onTrackLongPress: (ctx, track) => showTrackContextSheet(
        ctx,
        track: track,
        library: library,
        store: store,
      ),
    );
    await tester.longPress(find.text('Newest Song'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sheet-add-to-playlist')), findsOneWidget);
    expect(find.byKey(const Key('sheet-view-details')), findsOneWidget);
    // No desktop explorer entry on phone.
    expect(find.text('View in folder'), findsNothing);
  });

  testWidgets('drawer lists all entries and navigation switches the body', (
    tester,
  ) async {
    await pumpShell(tester, library: fixtureLibrary());
    await openDrawer(tester);
    for (final v in PhoneView.values) {
      expect(find.byKey(Key('phone-drawer-${v.name}')), findsOneWidget);
    }
    // Library is the active entry initially.
    expect(
      tester
          .widget<ListTile>(find.byKey(const Key('phone-drawer-library')))
          .selected,
      isTrue,
    );

    await tester.tap(find.byKey(const Key('phone-drawer-artists')));
    await tester.pumpAndSettle();
    // Drawer closed, AppBar retitled, placeholder body shown, feed gone.
    expect(find.byKey(const Key('phone-drawer-artists')), findsNothing);
    expect(find.text('Artists'), findsOneWidget);
    expect(find.text('coming soon'), findsOneWidget);
    expect(find.text('Newest Song'), findsNothing);

    // Re-open: the active highlight moved to Artists.
    await openDrawer(tester);
    expect(
      tester
          .widget<ListTile>(find.byKey(const Key('phone-drawer-artists')))
          .selected,
      isTrue,
    );
    expect(
      tester
          .widget<ListTile>(find.byKey(const Key('phone-drawer-library')))
          .selected,
      isFalse,
    );

    // And navigating back to Library restores the feed.
    await tester.tap(find.byKey(const Key('phone-drawer-library')));
    await tester.pumpAndSettle();
    expect(find.text('Newest Song'), findsOneWidget);
  });

  testWidgets('viewBuilders slot overrides a browse view body', (tester) async {
    await pumpShell(
      tester,
      library: fixtureLibrary(),
      viewBuilders: {PhoneView.folders: (_) => const Text('REAL FOLDERS VIEW')},
    );
    await openDrawer(tester);
    await tester.tap(find.byKey(const Key('phone-drawer-folders')));
    await tester.pumpAndSettle();
    expect(find.text('REAL FOLDERS VIEW'), findsOneWidget);
    expect(find.text('coming soon'), findsNothing);
  });

  testWidgets('miniPlayerBuilder slot renders at the Scaffold bottom', (
    tester,
  ) async {
    await pumpShell(
      tester,
      library: fixtureLibrary(),
      miniPlayerBuilder: (_) =>
          const SizedBox(key: Key('mini-player'), height: 64),
    );
    expect(find.byKey(const Key('mini-player')), findsOneWidget);
  });

  testWidgets('no activity model -> no strip, mini-player unaffected', (
    tester,
  ) async {
    await pumpShell(
      tester,
      library: fixtureLibrary(),
      miniPlayerBuilder: (_) =>
          const SizedBox(key: Key('mini-player'), height: 64),
    );
    expect(find.byKey(const Key('phone-activity-strip')), findsNothing);
    expect(find.byKey(const Key('mini-player')), findsOneWidget);
  });

  testWidgets('an idle activity model shows no strip', (tester) async {
    await pumpShell(
      tester,
      library: fixtureLibrary(),
      activity: ActivityModel(),
    );
    expect(find.byKey(const Key('phone-activity-strip')), findsNothing);
  });

  testWidgets('a background job shows the strip above the mini-player, sync '
      'surviving backgrounding was reported with NOTHING on the phone UI '
      'hinting a sync was even running', (tester) async {
    final activity = ActivityModel()..start('sync', 'Syncing with NAS');
    await pumpShell(
      tester,
      library: fixtureLibrary(),
      activity: activity,
      miniPlayerBuilder: (_) =>
          const SizedBox(key: Key('mini-player'), height: 64),
    );

    expect(find.byKey(const Key('phone-activity-strip')), findsOneWidget);
    expect(find.text('Syncing with NAS'), findsOneWidget);
    // The strip sits ABOVE the mini-player in the same bottom column.
    expect(
      tester.getTopLeft(find.byKey(const Key('phone-activity-strip'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('mini-player'))).dy),
    );
  });
}
