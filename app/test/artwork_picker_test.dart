// Plan 4 (Album Artwork Lookup) task A3 -- the shared picker widget.
//
// Everything the picker touches is injected through [ArtworkServices], so
// these tests drive the full flow with fakes: NO network (the thumbnail
// loader is a fake / the inert default), NO native file dialog (the file
// picker is a fake), NO filesystem writes (apply/remove just record calls).
// That is the plan's hard rule -- "tests inject fakes; no network, no real
// file dialogs" -- expressed as a property of the code, not a promise.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/artwork_picker.dart';
import 'package:fooplayer_app/artwork/picker_seams.dart';
import 'package:fooplayer_app/ui/app_theme.dart';

import 'support/artwork_fakes.dart';

/// Pumps the picker bare (no enclosing route) with [onFinished] captured --
/// the desktop-dialog and phone-page chromes are covered separately in
/// artwork_picker_entry_points_test.dart.
Future<List<ArtworkPickerOutcome>> pumpPicker(
  WidgetTester tester, {
  required ArtworkServices svc,
  String albumKey = 'muse|absolution',
  ArtworkQuery query = const ArtworkQuery(artist: 'Muse', album: 'Absolution'),
  bool settle = true,
}) async {
  final outcomes = <ArtworkPickerOutcome>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: SizedBox(
          width: 560,
          height: 480,
          child: ArtworkPicker(
            albumKey: albumKey,
            albumLabel: 'Muse — Absolution',
            query: query,
            services: svc,
            onFinished: outcomes.add,
          ),
        ),
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
  return outcomes;
}

void main() {
  testWidgets('grid renders one tile per candidate with source and '
      'resolution labels', (tester) async {
    final search = FakeArtworkSearch([
      [itunesCandidate, deezerCandidate, caaCandidate],
    ]);
    final store = FakeArtworkStore();
    await pumpPicker(
      tester,
      svc: fakeArtworkServices(search: search, store: store),
    );

    expect(find.byKey(const Key('artwork-candidate-grid')), findsOneWidget);
    for (var i = 0; i < 3; i++) {
      expect(find.byKey(Key('artwork-candidate-$i')), findsOneWidget);
    }
    // Source labels are the human names, not the raw sidecar ids.
    expect(find.text('iTunes'), findsOneWidget);
    expect(find.text('Deezer'), findsOneWidget);
    expect(find.text('Cover Art Archive'), findsOneWidget);
    // Resolution labels come from the candidate width; a candidate with no
    // reported width shows no fake resolution.
    expect(find.text('600 × 600'), findsOneWidget);
    expect(find.text('1000 × 1000'), findsOneWidget);
    expect(find.byKey(const Key('artwork-picker-empty')), findsNothing);
    // The search ran once, with the album's query, NOT force-refreshed.
    expect(search.calls, 1);
    expect(search.queries.single.artist, 'Muse');
    expect(search.queries.single.album, 'Absolution');
    expect(search.forceFlags.single, isFalse);
  });

  testWidgets('the stored selection is the only tile marked current', (
    tester,
  ) async {
    final search = FakeArtworkSearch([
      [itunesCandidate, deezerCandidate],
    ]);
    final store = FakeArtworkStore();
    await pumpPicker(
      tester,
      svc: fakeArtworkServices(
        search: search,
        store: store,
        currentSelectionId: (key) =>
            key == 'muse|absolution' ? deezerCandidate.url : null,
      ),
    );

    expect(find.byKey(const Key('artwork-current-marker')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('artwork-candidate-1')),
        matching: find.byKey(const Key('artwork-current-marker')),
      ),
      findsOneWidget,
    );
  });

  testWidgets('no candidates renders the empty state, not an error', (
    tester,
  ) async {
    final search = FakeArtworkSearch([<PickerCandidate>[]]);
    final store = FakeArtworkStore();
    await pumpPicker(
      tester,
      svc: fakeArtworkServices(search: search, store: store),
    );

    expect(find.byKey(const Key('artwork-picker-empty')), findsOneWidget);
    expect(find.byKey(const Key('artwork-picker-error')), findsNothing);
    // The manual paths stay available with nothing found.
    expect(find.byKey(const Key('artwork-choose-file')), findsOneWidget);
    expect(find.byKey(const Key('artwork-paste-url')), findsOneWidget);
  });

  testWidgets('selecting a candidate stores it under the album key and '
      'finishes as applied', (tester) async {
    final search = FakeArtworkSearch([
      [itunesCandidate, deezerCandidate],
    ]);
    final store = FakeArtworkStore();
    final outcomes = await pumpPicker(
      tester,
      svc: fakeArtworkServices(search: search, store: store),
      albumKey: 'muse|absolution',
    );

    await tester.tap(find.byKey(const Key('artwork-candidate-1')));
    await tester.pumpAndSettle();

    expect(store.appliedKeys, ['muse|absolution']);
    final choice = store.appliedChoices.single;
    expect(choice.source, ArtworkSource.deezer);
    expect(choice.url, deezerCandidate.url);
    expect(choice.localPath, isNull);
    expect(choice.width, 1000);
    // The sidecar's `query` field records what was searched.
    expect(choice.query, 'Muse Absolution');
    expect(outcomes, [ArtworkPickerOutcome.applied]);
    expect(store.removedKeys, isEmpty);
  });

  testWidgets('the album key the picker was opened with is what reaches the '
      'store, verbatim', (tester) async {
    final search = FakeArtworkSearch([
      [itunesCandidate],
    ]);
    final store = FakeArtworkStore();
    await pumpPicker(
      tester,
      svc: fakeArtworkServices(search: search, store: store),
      albumKey: 'pink floyd|the wall',
    );
    await tester.tap(find.byKey(const Key('artwork-candidate-0')));
    await tester.pumpAndSettle();

    expect(store.appliedKeys, ['pink floyd|the wall']);
  });

  testWidgets('Choose file stores the picked path as a local choice', (
    tester,
  ) async {
    final search = FakeArtworkSearch([
      [itunesCandidate],
    ]);
    final store = FakeArtworkStore();
    var pickCalls = 0;
    final outcomes = await pumpPicker(
      tester,
      svc: fakeArtworkServices(
        search: search,
        store: store,
        pickFile: () async {
          pickCalls++;
          return r'D:\covers\absolution.jpg';
        },
      ),
    );

    await tester.tap(find.byKey(const Key('artwork-choose-file')));
    await tester.pumpAndSettle();

    expect(pickCalls, 1);
    expect(store.appliedKeys, ['muse|absolution']);
    final choice = store.appliedChoices.single;
    expect(choice.source, ArtworkSource.local);
    expect(choice.localPath, r'D:\covers\absolution.jpg');
    expect(choice.url, isNull);
    expect(outcomes, [ArtworkPickerOutcome.applied]);
  });

  testWidgets('cancelling the file dialog changes nothing and leaves the '
      'picker open', (tester) async {
    final search = FakeArtworkSearch([
      [itunesCandidate],
    ]);
    final store = FakeArtworkStore();
    final outcomes = await pumpPicker(
      tester,
      svc: fakeArtworkServices(
        search: search,
        store: store,
        pickFile: () async => null,
      ),
    );

    await tester.tap(find.byKey(const Key('artwork-choose-file')));
    await tester.pumpAndSettle();

    expect(store.appliedKeys, isEmpty);
    expect(outcomes, isEmpty);
    expect(find.byKey(const Key('artwork-picker')), findsOneWidget);
  });

  testWidgets('Paste URL stores the typed URL as a url choice', (tester) async {
    final search = FakeArtworkSearch([
      [itunesCandidate],
    ]);
    final store = FakeArtworkStore();
    final outcomes = await pumpPicker(
      tester,
      svc: fakeArtworkServices(search: search, store: store),
    );

    await tester.tap(find.byKey(const Key('artwork-paste-url')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('artwork-url-dialog')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('artwork-url-field')),
      '  https://example.test/pasted.jpg  ',
    );
    await tester.tap(find.byKey(const Key('artwork-url-confirm')));
    await tester.pumpAndSettle();

    expect(store.appliedKeys, ['muse|absolution']);
    final choice = store.appliedChoices.single;
    expect(choice.source, ArtworkSource.url);
    expect(choice.url, 'https://example.test/pasted.jpg'); // trimmed
    expect(choice.localPath, isNull);
    expect(outcomes, [ArtworkPickerOutcome.applied]);
  });

  testWidgets('cancelling (or emptying) the URL prompt changes nothing', (
    tester,
  ) async {
    final search = FakeArtworkSearch([
      [itunesCandidate],
    ]);
    final store = FakeArtworkStore();
    final outcomes = await pumpPicker(
      tester,
      svc: fakeArtworkServices(search: search, store: store),
    );

    await tester.tap(find.byKey(const Key('artwork-paste-url')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('artwork-url-cancel')));
    await tester.pumpAndSettle();
    expect(store.appliedKeys, isEmpty);

    // An empty confirm is treated as a cancel, not a blank URL.
    await tester.tap(find.byKey(const Key('artwork-paste-url')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('artwork-url-confirm')));
    await tester.pumpAndSettle();

    expect(store.appliedKeys, isEmpty);
    expect(outcomes, isEmpty);
  });

  testWidgets('Search again re-queries with the negative cache bypassed and '
      'swaps the grid', (tester) async {
    final search = FakeArtworkSearch([
      [itunesCandidate],
      [deezerCandidate, caaCandidate],
    ]);
    final store = FakeArtworkStore();
    await pumpPicker(
      tester,
      svc: fakeArtworkServices(search: search, store: store),
    );

    expect(find.text('iTunes'), findsOneWidget);
    expect(find.byKey(const Key('artwork-candidate-1')), findsNothing);

    await tester.tap(find.byKey(const Key('artwork-search-again')));
    await tester.pumpAndSettle();

    expect(search.calls, 2);
    expect(search.forceFlags, [false, true]); // manual search bypasses cache
    expect(find.text('iTunes'), findsNothing);
    expect(find.text('Deezer'), findsOneWidget);
    expect(find.byKey(const Key('artwork-candidate-1')), findsOneWidget);
    // Re-searching is not a store write.
    expect(store.appliedKeys, isEmpty);
    expect(store.removedKeys, isEmpty);
  });

  testWidgets('Remove artwork clears the album key and finishes as removed', (
    tester,
  ) async {
    final search = FakeArtworkSearch([
      [itunesCandidate],
    ]);
    final store = FakeArtworkStore();
    final outcomes = await pumpPicker(
      tester,
      svc: fakeArtworkServices(
        search: search,
        store: store,
        currentSelectionId: (_) => itunesCandidate.url,
      ),
      albumKey: 'muse|absolution',
    );

    await tester.tap(find.byKey(const Key('artwork-remove')));
    await tester.pumpAndSettle();

    expect(store.removedKeys, ['muse|absolution']);
    expect(store.appliedKeys, isEmpty);
    expect(outcomes, [ArtworkPickerOutcome.removed]);
  });

  testWidgets('a search still in flight shows the loading state and no grid', (
    tester,
  ) async {
    final search = FakeArtworkSearch([
      [itunesCandidate],
    ])..gate = Completer<List<PickerCandidate>>();
    final store = FakeArtworkStore();
    await pumpPicker(
      tester,
      svc: fakeArtworkServices(search: search, store: store),
      settle: false,
    );
    await tester.pump();

    expect(find.byKey(const Key('artwork-picker-loading')), findsOneWidget);
    expect(find.byKey(const Key('artwork-candidate-grid')), findsNothing);

    search.gate!.complete([itunesCandidate]);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('artwork-picker-loading')), findsNothing);
    expect(find.byKey(const Key('artwork-candidate-0')), findsOneWidget);
  });

  testWidgets('a search that throws leaves a usable picker, not a crash', (
    tester,
  ) async {
    final store = FakeArtworkStore();
    await pumpPicker(
      tester,
      svc: ArtworkServices(
        search: (q, {bool forceRefresh = false}) =>
            Future<List<PickerCandidate>>.error(StateError('boom')),
        apply: store.apply,
        remove: store.remove,
        pickFile: () async => null,
      ),
    );

    expect(find.byKey(const Key('artwork-picker-error')), findsOneWidget);
    expect(find.byKey(const Key('artwork-remove')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a store failure keeps the picker open and reports it', (
    tester,
  ) async {
    final search = FakeArtworkSearch([
      [itunesCandidate],
    ]);
    final store = FakeArtworkStore()..applyError = StateError('disk full');
    final outcomes = await pumpPicker(
      tester,
      svc: fakeArtworkServices(search: search, store: store),
    );

    await tester.tap(find.byKey(const Key('artwork-candidate-0')));
    await tester.pumpAndSettle();

    expect(outcomes, isEmpty);
    expect(find.byKey(const Key('artwork-picker-error')), findsOneWidget);
    expect(find.byKey(const Key('artwork-candidate-0')), findsOneWidget);
  });

  testWidgets('the default thumbnail loader fetches nothing -- tiles show the '
      'placeholder (no network, ever)', (tester) async {
    final search = FakeArtworkSearch([
      [itunesCandidate],
    ]);
    final store = FakeArtworkStore();
    await pumpPicker(
      tester,
      svc: fakeArtworkServices(search: search, store: store),
    );

    expect(find.byIcon(Icons.album), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('thumbnails render the injected loader\'s bytes, requested for '
      'the candidate preview URL', (tester) async {
    final search = FakeArtworkSearch([
      [itunesCandidate, deezerCandidate],
    ]);
    final store = FakeArtworkStore();
    final requested = <String>[];
    await pumpPicker(
      tester,
      svc: fakeArtworkServices(
        search: search,
        store: store,
        loadThumb: (url) async {
          requested.add(url);
          return onePixelPng;
        },
      ),
    );

    // The small preview is used when the provider gave one; a candidate
    // with no thumbUrl falls back to its full-size url.
    expect(requested, [itunesCandidate.thumbUrl, deezerCandidate.url]);
    expect(find.byType(Image), findsNWidgets(2));
  });

  group('album key + query derivation (placeholder normalizer)', () {
    test('album key is normalizedArtist|normalizedAlbum', () {
      expect(albumKeyForTrack(artworkFixtureTrack()), 'muse|absolution');
    });

    test('bracketed suffixes and punctuation are dropped', () {
      expect(
        albumKeyForTrack(
          artworkFixtureTrack(
            artist: 'Pink Floyd',
            album: 'The Wall (Deluxe Edition) [Explicit]',
          ),
        ),
        'pink floyd|the wall',
      );
    });

    test('a track with no album falls back to artist|title', () {
      expect(
        albumKeyForTrack(
          artworkFixtureTrack(title: 'Untitled Demo', album: ''),
        ),
        'muse|untitled demo',
      );
    });

    test('the query mirrors the key fallback', () {
      expect(
        artworkQueryForTrack(artworkFixtureTrack()).term,
        'Muse Absolution',
      );
      expect(
        artworkQueryForTrack(
          artworkFixtureTrack(title: 'Demo', album: ''),
        ).term,
        'Muse Demo',
      );
    });

    test('source labels fall back to the raw sidecar id', () {
      expect(artworkSourceLabel(ArtworkSource.itunes), 'iTunes');
      expect(
        artworkSourceLabel(ArtworkSource.coverArtArchive),
        'Cover Art Archive',
      );
      expect(artworkSourceLabel('discogs'), 'discogs');
    });
  });
}
