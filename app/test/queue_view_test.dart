// The queue as something you can look at and rearrange.
//
// It used to be invisible and write-once: tapping a song replaced it
// wholesale, and there was no way to see what was lined up. "Play next" means
// nothing if you cannot see what next is.
//
// The rule these tests keep circling is that the row showing as playing must
// be the track actually playing -- so the current row can't be removed (the
// audio would carry on regardless) and a drag elsewhere must not silently
// change which row is current.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/now_playing_bar.dart' show AlbumArt;
import 'package:fooplayer_app/ui/queue_view.dart';
import 'package:fooplayer_app/ui/track_list.dart' show SongCell;

Track _t(
  String id, {
  String title = '',
  String artist = 'An Artist',
  String album = '',
  int? durationMs,
}) => Track(
  contentId: id,
  relPath: '$id.mp3',
  dateAdded: DateTime.utc(2024),
  title: title.isEmpty ? 'Song $id' : title,
  artist: artist,
  album: album,
  durationMs: durationMs,
);

/// A player whose queue can be driven without an audio engine.
class _FakePlayer extends PlayerService {
  final opened = <int>[];

  @override
  Future<void> playQueueIndex(int i) async {
    opened.add(i);
    queueController.setIndex(i);
    notifyListeners();
  }
}

Future<void> _pump(WidgetTester tester, PlayerService player,
        {bool header = false}) =>
    tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: QueueView(player: player, showHeader: header),
        ),
      ),
    );

void main() {
  testWidgets('an empty queue says how to fill it', (tester) async {
    await _pump(tester, _FakePlayer());
    expect(find.byKey(const Key('queue-empty')), findsOneWidget);
    expect(find.textContaining('Play next'), findsOneWidget);
  });

  testWidgets('lists the queue and marks what is playing', (tester) async {
    final p = _FakePlayer()
      ..queueController.setQueue([_t('a'), _t('b'), _t('c')], 1);
    await _pump(tester, p);

    expect(find.text('Song a'), findsOneWidget);
    expect(find.text('Song b'), findsOneWidget);
    expect(find.text('Song c'), findsOneWidget);
    // The playing row gets the speaker, and no remove button.
    expect(find.byIcon(Icons.volume_up), findsOneWidget);
    expect(find.byKey(const Key('queue-remove-1')), findsNothing);
    expect(find.byKey(const Key('queue-remove-0')), findsOneWidget);
    expect(find.byKey(const Key('queue-remove-2')), findsOneWidget);
  });

  testWidgets('tapping a row jumps to it', (tester) async {
    final p = _FakePlayer()
      ..queueController.setQueue([_t('a'), _t('b'), _t('c')], 0);
    await _pump(tester, p);

    await tester.tap(find.text('Song c'));
    await tester.pumpAndSettle();

    expect(p.opened, [2]);
  });

  testWidgets('removing a row takes it out of the queue', (tester) async {
    final p = _FakePlayer()
      ..queueController.setQueue([_t('a'), _t('b'), _t('c')], 0);
    await _pump(tester, p);

    await tester.tap(find.byKey(const Key('queue-remove-2')));
    await tester.pumpAndSettle();

    expect(find.text('Song c'), findsNothing);
    expect(p.queueController.queue, hasLength(2));
    expect(p.queueController.current!.contentId, 'a');
  });

  testWidgets('the header counts what is still to come, and clears it', (
    tester,
  ) async {
    final p = _FakePlayer()
      ..queueController.setQueue([_t('a'), _t('b'), _t('c')], 0);
    await _pump(tester, p, header: true);

    expect(find.text('2 to come'), findsOneWidget);

    await tester.tap(find.byKey(const Key('queue-clear')));
    await tester.pumpAndSettle();

    expect(p.queueController.queue, hasLength(1));
    expect(find.text('nothing after this'), findsOneWidget);
    expect(
      find.text('Song a'),
      findsOneWidget,
      reason: 'clearing what is next must not stop what is playing',
    );
  });

  testWidgets('Clear is disabled when there is nothing to clear', (
    tester,
  ) async {
    final p = _FakePlayer()..queueController.setQueue([_t('a')], 0);
    await _pump(tester, p, header: true);

    final button = tester.widget<TextButton>(
      find.byKey(const Key('queue-clear')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets(
    'every row carries a cover, the same widget the playlist view uses',
    (tester) async {
      final p = _FakePlayer()
        ..queueController.setQueue([_t('a'), _t('b'), _t('c')], 0);
      await _pump(tester, p);

      expect(
        find.byType(AlbumArt),
        findsNWidgets(3),
        reason:
            '"formatted like any other playlist, with art showing" -- one '
            'cover per row',
      );
    },
  );

  testWidgets(
    'rows are the SAME SongCell the playlist view uses, not a look-alike '
    'copy -- "the cue does not match the playlist view"',
    (tester) async {
      final p = _FakePlayer()
        ..queueController.setQueue([_t('a'), _t('b'), _t('c')], 0);
      await _pump(tester, p);

      expect(find.byType(SongCell), findsNWidgets(3));
    },
  );

  testWidgets(
    'the column header matches the playlist view: #, Song, Album, Time',
    (tester) async {
      final p = _FakePlayer()..queueController.setQueue([_t('a')], 0);
      await _pump(tester, p);

      expect(find.text('#'), findsOneWidget);
      expect(find.text('SONG'), findsOneWidget);
      expect(find.text('ALBUM'), findsOneWidget);
      expect(find.text('TIME'), findsOneWidget);
    },
  );

  testWidgets('rows show Album and Time, same as a playlist row', (
    tester,
  ) async {
    final p = _FakePlayer()
      ..queueController.setQueue([
        _t('a', album: 'First Album', durationMs: 245000),
      ], 0);
    await _pump(tester, p);

    expect(find.text('First Album'), findsOneWidget);
    expect(find.text('4:05'), findsOneWidget);
  });

  testWidgets('the view follows the queue as it changes', (tester) async {
    final p = _FakePlayer()..queueController.setQueue([_t('a')], 0);
    await _pump(tester, p);
    expect(find.text('Song b'), findsNothing);

    await p.addToQueue([_t('b')]);
    await tester.pumpAndSettle();

    expect(find.text('Song b'), findsOneWidget);
  });

  testWidgets('opens scrolled to the playing track, not row zero', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final p = _FakePlayer()
      ..queueController.setQueue(
        [for (var i = 0; i < 80; i++) _t('t$i')],
        60,
      );
    await _pump(tester, p);
    await tester.pumpAndSettle();

    // Far-down current track is on screen without any user scrolling; the
    // head of the queue is not.
    expect(find.text('Song t60'), findsOneWidget);
    expect(find.text('Song t0'), findsNothing);
  });
}
