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
import 'package:fooplayer_app/ui/queue_view.dart';

Track _t(String id, {String title = '', String artist = 'An Artist'}) => Track(
  contentId: id,
  relPath: '$id.mp3',
  dateAdded: DateTime.utc(2024),
  title: title.isEmpty ? 'Song $id' : title,
  artist: artist,
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

  testWidgets('the view follows the queue as it changes', (tester) async {
    final p = _FakePlayer()..queueController.setQueue([_t('a')], 0);
    await _pump(tester, p);
    expect(find.text('Song b'), findsNothing);

    await p.addToQueue([_t('b')]);
    await tester.pumpAndSettle();

    expect(find.text('Song b'), findsOneWidget);
  });
}
