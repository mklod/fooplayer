import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/queue_controller.dart';

Track tr(String id) => Track(
    contentId: id, relPath: '$id.mp3', dateAdded: DateTime.utc(2024), title: id);

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

  test('shuffle keeps current, reorders upcoming deterministically, off restores', () {
    final q = QueueController();
    q.setQueue(tracks, 1); // current b; upcoming c,d
    q.toggleShuffle((n) => n - 1); // deterministic: pick last each time → reversed
    expect(q.current!.contentId, 'b');
    final order = [q.advance()!.contentId, q.advance()!.contentId];
    expect(order, ['d', 'c']); // reversed by our fake randomBelow
    q.toggleShuffle((n) => 0); // OFF: restore original order, keep position
    expect(q.current!.contentId, 'c'); // last-played track remains current
    expect(q.advance()!.contentId, 'd'); // original order resumes
  });
}
