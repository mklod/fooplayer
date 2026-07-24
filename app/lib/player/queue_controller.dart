import '../model/track.dart';

class QueueController {
  List<Track> _original = [];
  List<Track> _queue = [];
  int _index = -1;
  bool shuffle = false;

  List<Track> get queue => List.unmodifiable(_queue);
  int get index => _index;
  Track? get current =>
      (_index >= 0 && _index < _queue.length) ? _queue[_index] : null;

  void setQueue(List<Track> tracks, int startIndex) {
    _original = List.of(tracks);
    _queue = List.of(tracks);
    _index = startIndex;
    shuffle = false;
  }

  Track? advance() {
    if (_index + 1 >= _queue.length) return null;
    _index++;
    return current;
  }

  Track? previous() {
    if (_index > 0) _index--;
    return current;
  }

  /// randomBelow(n) returns an int in [0, n). Inject Random().nextInt for
  /// production; a deterministic function in tests.
  void toggleShuffle(int Function(int) randomBelow) {
    if (!shuffle) {
      shuffle = true;
      final upcoming = _queue.sublist(_index + 1);
      for (var i = upcoming.length - 1; i > 0; i--) {
        final j = randomBelow(i + 1);
        final tmp = upcoming[i];
        upcoming[i] = upcoming[j];
        upcoming[j] = tmp;
      }
      _queue = [..._queue.sublist(0, _index + 1), ...upcoming];
    } else {
      shuffle = false;
      final cur = current;
      _queue = List.of(_original);
      _index = cur == null
          ? -1
          : _queue.indexWhere((t) => t.contentId == cur.contentId);
    }
  }
}
