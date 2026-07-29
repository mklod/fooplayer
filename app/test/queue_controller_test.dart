import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/queue_controller.dart';

Track tr(String id) => Track(
  contentId: id,
  relPath: '$id.mp3',
  dateAdded: DateTime.utc(2024),
  title: id,
);

void main() {
  final tracks = ['a', 'b', 'c', 'd'].map(tr).toList();

  test('setQueue and linear advance to end', () {
    final q = QueueController();
    q.setQueue(tracks, 1);
    expect(q.current!.contentId, 'b');
    expect(q.advance()!.contentId, 'c');
    expect(q.advance()!.contentId, 'd');
    expect(q.advance(), isNull); // end of queue
  });

  test('previous restarts at start of queue', () {
    final q = QueueController();
    q.setQueue(tracks, 0);
    expect(q.previous()!.contentId, 'a');
  });

  test(
    'shuffle keeps current, reorders upcoming deterministically, off restores',
    () {
      final q = QueueController();
      q.setQueue(tracks, 1); // current b; upcoming c,d
      q.toggleShuffle(
        (n) => 0,
      ); // deterministic: pick first each time (Fisher-Yates) → reversed
      expect(q.current!.contentId, 'b');
      final order = [q.advance()!.contentId, q.advance()!.contentId];
      expect(order, ['d', 'c']); // reversed by our fake randomBelow
      q.toggleShuffle((n) => 0); // OFF: restore original order, keep position
      expect(q.current!.contentId, 'c'); // last-played track remains current
      expect(q.advance()!.contentId, 'd'); // original order resumes
    },
  );

  group('the queue as a scratch playlist', () {
    QueueController seeded() =>
        QueueController()..setQueue([tr('a'), tr('b'), tr('c')], 0);

    test('play next lands immediately after what is playing', () {
      final q = seeded()..insertNext([tr('x')]);
      expect(q.queue.map((t) => t.contentId), ['a', 'x', 'b', 'c']);
      expect(q.current!.contentId, 'a', reason: 'playback is undisturbed');
      expect(q.advance()!.contentId, 'x');
    });

    test('add to queue lands at the end', () {
      final q = seeded()..append([tr('x'), tr('y')]);
      expect(q.queue.map((t) => t.contentId), ['a', 'b', 'c', 'x', 'y']);
    });

    test('several play-nexts keep the order they were given', () {
      final q = seeded()..insertNext([tr('x'), tr('y')]);
      expect(q.queue.map((t) => t.contentId), ['a', 'x', 'y', 'b', 'c']);
    });

    test('on an idle player, either becomes the queue', () {
      expect(
        (QueueController()..insertNext([tr('x')])).current!.contentId,
        'x',
      );
      expect((QueueController()..append([tr('y')])).current!.contentId, 'y');
    });

    test('upcoming is what is left after the current track', () {
      final q = seeded();
      expect(q.upcoming.map((t) => t.contentId), ['b', 'c']);
      q.advance();
      q.advance();
      expect(q.upcoming, isEmpty);
    });

    test('an added track survives a shuffle round trip', () {
      // The bug this prevents: adding only to the play order, so toggling
      // shuffle off rebuilds from the source list and the track vanishes.
      final q = seeded()..insertNext([tr('x')]);
      q.toggleShuffle((n) => 0);
      q.toggleShuffle((n) => 0);
      expect(q.queue.map((t) => t.contentId), contains('x'));
      expect(q.current!.contentId, 'a');
    });
  });

  group('editing the queue', () {
    QueueController seeded() =>
        QueueController()..setQueue([tr('a'), tr('b'), tr('c'), tr('d')], 1);

    test('removing something ahead leaves the current track alone', () {
      final q = seeded();
      expect(q.removeAt(2), isTrue);
      expect(q.queue.map((t) => t.contentId), ['a', 'b', 'd']);
      expect(q.current!.contentId, 'b');
    });

    test('removing something behind keeps the index on the same track', () {
      final q = seeded();
      expect(q.removeAt(0), isTrue);
      expect(q.current!.contentId, 'b', reason: 'still playing the same one');
    });

    test('the playing track cannot be removed out from under itself', () {
      final q = seeded();
      expect(
        q.removeAt(1),
        isFalse,
        reason: 'the audio would carry on, so current would name the wrong '
            'track',
      );
      expect(q.queue, hasLength(4));
    });

    test('out-of-range removals are refused, not crashes', () {
      final q = seeded();
      expect(q.removeAt(-1), isFalse);
      expect(q.removeAt(99), isFalse);
    });

    test('dragging an item keeps the same track playing', () {
      final q = seeded(); // playing 'b' at 1
      expect(q.move(3, 0), isTrue);
      expect(q.queue.map((t) => t.contentId), ['d', 'a', 'b', 'c']);
      expect(q.current!.contentId, 'b', reason: 'same track, new slot');
    });

    test('dragging the playing track moves the index with it', () {
      final q = seeded();
      expect(q.move(1, 3), isTrue);
      expect(q.queue.map((t) => t.contentId), ['a', 'c', 'd', 'b']);
      expect(q.current!.contentId, 'b');
    });

    test('dragging from ahead to behind still tracks the current song', () {
      final q = seeded();
      q.move(0, 3); // 'a' from before the current track to the end
      expect(q.current!.contentId, 'b');
    });

    test('a no-op or invalid drag changes nothing', () {
      final q = seeded();
      expect(q.move(1, 1), isFalse);
      expect(q.move(-1, 2), isFalse);
      expect(q.move(0, 99), isFalse);
      expect(q.queue.map((t) => t.contentId), ['a', 'b', 'c', 'd']);
    });

    test('clearing upcoming leaves the current track playing', () {
      final q = seeded()..clearUpcoming();
      expect(q.queue.map((t) => t.contentId), ['a', 'b']);
      expect(q.current!.contentId, 'b');
      expect(q.upcoming, isEmpty);
    });
  });
}
