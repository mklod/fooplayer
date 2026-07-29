import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:path/path.dart' as p;
import '../model/track.dart';
import 'queue_controller.dart';

class PlayerService extends ChangeNotifier {
  final QueueController queueController = QueueController();
  final _rng = Random();

  Player? _player; // lazy: never constructed in widget tests
  bool playing = false;
  Duration position = Duration.zero;
  Duration? duration;
  double volume = 1.0;

  /// The contentId [_openCurrent] confirmed the engine has *finished*
  /// opening -- i.e. the only track [handleDurationChange] will attribute an
  /// observed duration to. Recorded only once `player.open()` for that
  /// track resolves (not when the track becomes [queueController]'s
  /// `current`, which happens synchronously and *earlier*, at the top of
  /// [_openCurrent]).
  ///
  /// That ordering is what closes the race this guards against: rapid
  /// next/next/next (A->B->C) advances `current` synchronously well ahead
  /// of the engine, so a `duration` stream event for B that's merely
  /// delayed (media_kit/mpv hadn't finished probing it before the user
  /// skipped again) can otherwise arrive after `current == C` and get
  /// misattributed to C -- permanently, since [handleDurationChange]'s
  /// `durationMs == null` gate then blocks any future correction. media_kit
  /// serializes every `Player.open()` call through an internal lock and
  /// each one *starts* by stopping/tearing down whatever was previously
  /// loaded, so a stale event genuinely belonging to a previous track is
  /// always delivered before the next open() resolves -- i.e. before this
  /// field advances past that track's id. Comparing against `current`
  /// instead (which already flips the instant a skip is requested, not once
  /// the engine catches up) would not detect this: it would already equal
  /// whatever's newly current by the time the stale event arrives.
  String? _openedContentId;

  /// On-play duration backfill hook: invoked (when set) each time the
  /// engine reports a real, nonzero duration for the current track *and*
  /// that track's library metadata has no [Track.durationMs] of its own --
  /// i.e. exactly the tracks whose Time column is blank because the tag
  /// parser couldn't derive a duration at scan time (e.g. an MP3 whose
  /// APEv2 tag routes it to a parser with no stream-duration logic; see
  /// metadata/tags.dart's `_readRawTags` dispatch). main.dart wires this to
  /// [LibraryModel.updateDuration] so any such track permanently gains its
  /// duration the first time it's played. Tracks that already have a
  /// durationMs never re-invoke this -- the engine's value would just
  /// restate what the library already knows.
  void Function(String contentId, Duration duration)? onObservedDuration;

  PlayerService();

  Track? get current => queueController.current;
  bool get shuffle => queueController.shuffle;

  Player _ensurePlayer() {
    if (_player != null) return _player!;
    final player = Player();
    player.stream.position.listen((d) {
      position = d;
      notifyListeners();
    });
    player.stream.duration.listen(handleDurationChange);
    player.stream.playing.listen((v) {
      playing = v;
      notifyListeners();
    });
    player.stream.completed.listen((done) {
      if (done) next();
    });
    _player = player;
    return player;
  }

  /// The `player.stream.duration` listener body (see [_ensurePlayer]),
  /// extracted so tests can drive duration changes directly -- constructing
  /// a real media_kit [Player] needs natives no test environment here has.
  /// Mirrors the engine's duration into [duration] and, when it's a real
  /// (nonzero) value for a current track the library has no duration for,
  /// reports it via [onObservedDuration] (see its doc for why that gate).
  @visibleForTesting
  void handleDurationChange(Duration d) {
    duration = d;
    final t = queueController.current;
    if (d > Duration.zero &&
        t != null &&
        t.durationMs == null &&
        t.contentId == _openedContentId) {
      onObservedDuration?.call(t.contentId, d);
    }
    notifyListeners();
  }

  /// Test-only hook mirroring what a real [_openCurrent] call records once
  /// its `player.open()` resolves (see [_openedContentId]'s doc) -- lets
  /// tests drive [handleDurationChange] realistically without a real
  /// media_kit [Player], which needs natives no test environment here has.
  @visibleForTesting
  void debugMarkOpened(String? contentId) {
    _openedContentId = contentId;
  }

  Future<void> _openCurrent() async {
    final t = queueController.current;
    if (t == null) {
      _openedContentId = null;
      await _player?.stop();
      return;
    }
    final path = p.join(t.rootPath, t.relPath);
    await _ensurePlayer().open(Media(path), play: true);
    // Only now -- once the engine has actually finished switching to this
    // track -- does it become the one a duration event can be attributed
    // to. See [_openedContentId]'s doc for why the timing matters.
    _openedContentId = t.contentId;
    notifyListeners();
  }

  Future<void> playFrom(List<Track> tracks, int index) async {
    queueController.setQueue(tracks, index);
    await _openCurrent();
  }

  Future<void> togglePlayPause() async {
    await _player?.playOrPause();
  }

  /// Explicit transport, for callers that know which they mean.
  ///
  /// The lock screen and notification send `play` and `pause` as distinct
  /// commands, and Android may send either when it thinks state has drifted.
  /// Answering both with a toggle turns a redundant "play" into a pause --
  /// the button does the opposite of what it says.
  Future<void> play() async => _player?.play();

  Future<void> pause() async => _player?.pause();

  Future<void> next() async {
    if (queueController.advance() != null) {
      await _openCurrent();
    } else {
      await _player?.stop();
      playing = false;
      notifyListeners();
    }
  }

  Future<void> previous() async {
    queueController.previous();
    await _openCurrent();
  }

  Future<void> seek(Duration d) async => _player?.seek(d);

  Future<void> setVolume(double v01) async {
    volume = v01.clamp(0.0, 1.0);
    await _player?.setVolume(volume * 100);
    notifyListeners();
  }

  void toggleShuffle() {
    queueController.toggleShuffle(_rng.nextInt);
    notifyListeners();
  }

  @override
  Future<void> dispose() async {
    await _player?.dispose();
    super.dispose();
  }
}
