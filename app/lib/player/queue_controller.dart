import '../model/track.dart';

/// What is playing and what is lined up behind it.
///
/// The queue is editable -- a scratch playlist you build as you go. Two
/// orders are tracked: [_queue] is the play order, [_original] the order to
/// return to when shuffle is switched off. Anything added has to land in both
/// or it would vanish the moment shuffle was toggled.
class QueueController {
  List<Track> _original = [];
  List<Track> _queue = [];
  int _index = -1;
  bool shuffle = false;

  List<Track> get queue => List.unmodifiable(_queue);
  int get index => _index;
  Track? get current =>
      (_index >= 0 && _index < _queue.length) ? _queue[_index] : null;

  /// Everything lined up after the current track -- what a queue view shows.
  List<Track> get upcoming =>
      _index + 1 >= _queue.length ? const [] : _queue.sublist(_index + 1);

  void setQueue(List<Track> tracks, int startIndex) {
    _original = List.of(tracks);
    _queue = List.of(tracks);
    _index = startIndex;
    shuffle = false;
  }

  /// Puts [tracks] immediately after the current track, in the order given.
  ///
  /// With nothing playing this simply becomes the queue, so "play next" on an
  /// idle player does something sensible rather than nothing.
  void insertNext(Iterable<Track> tracks) {
    final add = List.of(tracks);
    if (add.isEmpty) return;
    if (_index < 0 || _queue.isEmpty) {
      setQueue(add, 0);
      return;
    }
    _queue.insertAll(_index + 1, add);
    // Mirror into the un-shuffled order so an unshuffle keeps them. Position
    // is by the current track, which is the only anchor both lists share.
    final anchor = _originalIndexOfCurrent();
    _original.insertAll(anchor + 1, add);
  }

  /// Puts [tracks] at the end of the queue.
  void append(Iterable<Track> tracks) {
    final add = List.of(tracks);
    if (add.isEmpty) return;
    if (_index < 0 || _queue.isEmpty) {
      setQueue(add, 0);
      return;
    }
    _queue.addAll(add);
    _original.addAll(add);
  }

  /// Drops the entry at [i] from the queue.
  ///
  /// Refuses to remove what is currently playing: the audio would carry on
  /// regardless, so [current] would name one track while another was audible.
  /// Skip it instead. Returns whether anything was removed.
  bool removeAt(int i) {
    if (i < 0 || i >= _queue.length || i == _index) return false;
    final gone = _queue.removeAt(i);
    final o = _original.indexWhere((t) => t.contentId == gone.contentId);
    if (o >= 0) _original.removeAt(o);
    if (i < _index) _index--;
    return true;
  }

  /// Moves the entry at [from] to [to], as a drag in a queue list does.
  ///
  /// Only ever reorders the play order. When shuffled, [_original] is
  /// deliberately left alone -- it is the order to come back to, and
  /// rearranging the shuffle is not a statement about that.
  bool move(int from, int to) {
    if (from < 0 || from >= _queue.length) return false;
    if (to < 0 || to >= _queue.length || from == to) return false;
    final moved = _queue.removeAt(from);
    _queue.insert(to, moved);

    // The current track has to keep pointing at the same track, not the same
    // slot -- otherwise a drag elsewhere in the list silently changes what is
    // considered playing.
    final cur = _index;
    if (from == cur) {
      _index = to;
    } else if (from < cur && to >= cur) {
      _index--;
    } else if (from > cur && to <= cur) {
      _index++;
    }

    if (!shuffle) {
      final o = _original.removeAt(from);
      _original.insert(to, o);
    }
    return true;
  }

  /// Jumps to a position, for tapping a row in the queue view.
  bool setIndex(int i) {
    if (i < 0 || i >= _queue.length) return false;
    _index = i;
    return true;
  }

  /// Empties everything after the current track, leaving it playing.
  void clearUpcoming() {
    if (_index < 0 || _index + 1 >= _queue.length) return;
    final dropped = _queue.sublist(_index + 1).map((t) => t.contentId).toSet();
    _queue.removeRange(_index + 1, _queue.length);
    _original.removeWhere(
      (t) => dropped.contains(t.contentId) && t.contentId != current?.contentId,
    );
  }

  int _originalIndexOfCurrent() {
    final cur = current;
    if (cur == null) return _original.length - 1;
    final i = _original.indexWhere((t) => t.contentId == cur.contentId);
    return i < 0 ? _original.length - 1 : i;
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
