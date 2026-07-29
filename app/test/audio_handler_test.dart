// The media session: what Android is told, and what it can tell us.
//
// The failure mode this guards against is a notification that disagrees with
// the sound coming out -- a pause button showing "play", a lock screen stuck
// on the previous track. That happens when the handler keeps state of its
// own, so PlayerService stays the single source of truth and everything here
// checks that the published state follows it rather than leading it.
import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/audio_handler.dart';
import 'package:fooplayer_app/player/player_service.dart';

Track _track(
  String id, {
  String title = 'A Song',
  String artist = 'An Artist',
  String album = 'An Album',
  int? durationMs,
}) => Track(
  contentId: id,
  relPath: '$id.mp3',
  rootPath: r'L:\M',
  dateAdded: DateTime.utc(2024),
  title: title,
  artist: artist,
  album: album,
  durationMs: durationMs,
);

/// A PlayerService with no engine behind it. Every transport call is
/// recorded rather than performed -- constructing a real media_kit Player
/// needs natives no test environment here has.
class _SpyPlayer extends PlayerService {
  final calls = <String>[];

  @override
  Future<void> play() async {
    calls.add('play');
    playing = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    playing = false;
    notifyListeners();
  }

  @override
  Future<void> next() async => calls.add('next');

  @override
  Future<void> previous() async => calls.add('previous');

  @override
  Future<void> seek(Duration d) async => calls.add('seek:${d.inSeconds}');

  /// Puts [t] on as the current track without touching an engine.
  void stage(Track t) {
    queueController.setQueue([t], 0);
    notifyListeners();
  }
}

void main() {
  late _SpyPlayer player;
  late FooplayerAudioHandler handler;

  setUp(() {
    player = _SpyPlayer();
    handler = FooplayerAudioHandler(player: player);
  });
  tearDown(() => handler.close());

  group('what Android is shown', () {
    test('the track becomes the media item', () {
      player.stage(
        _track('a', title: 'Teardrop', artist: 'Massive Attack',
            album: 'Mezzanine', durationMs: 330000),
      );

      final item = handler.mediaItem.value!;
      expect(item.id, 'a');
      expect(item.title, 'Teardrop');
      expect(item.artist, 'Massive Attack');
      expect(item.album, 'Mezzanine');
      expect(item.duration, const Duration(milliseconds: 330000));
    });

    test('an empty artist or album is left off, not shown blank', () {
      player.stage(_track('a', artist: '', album: ''));
      expect(handler.mediaItem.value!.artist, isNull);
      expect(handler.mediaItem.value!.album, isNull);
    });

    test('the button follows the player, so it never lies', () async {
      player.stage(_track('a'));
      expect(
        handler.playbackState.value.controls.map((c) => c.action),
        contains(MediaAction.play),
      );

      await player.play();
      expect(
        handler.playbackState.value.playing,
        isTrue,
        reason: 'the notification must say what is actually happening',
      );
      expect(
        handler.playbackState.value.controls.map((c) => c.action),
        contains(MediaAction.pause),
      );
    });

    test('all three transport buttons show without expanding', () {
      player.stage(_track('a'));
      expect(handler.playbackState.value.androidCompactActionIndices,
          [0, 1, 2]);
      expect(handler.playbackState.value.controls, hasLength(3));
    });

    test('the clock only advances while playing', () async {
      player.stage(_track('a'));
      expect(handler.playbackState.value.speed, 0.0);
      await player.play();
      expect(handler.playbackState.value.speed, 1.0);
    });

    test('nothing playing means no media item at all', () {
      expect(handler.mediaItem.value, isNull);
    });
  });

  group('what Android can tell us', () {
    test('play and pause are distinct, not a toggle', () async {
      player.stage(_track('a'));

      await handler.play();
      await handler.play();
      expect(
        player.calls,
        ['play', 'play'],
        reason: 'a second play must not pause -- the button would lie',
      );

      await handler.pause();
      expect(player.calls.last, 'pause');
    });

    test('skip and seek reach the player', () async {
      await handler.skipToNext();
      await handler.skipToPrevious();
      await handler.seek(const Duration(seconds: 42));
      expect(player.calls, ['next', 'previous', 'seek:42']);
    });

    test('swiping the app away stops playback', () async {
      player.stage(_track('a'));
      await player.play();

      await handler.onTaskRemoved();

      expect(player.calls, contains('pause'));
      expect(handler.playbackState.value.playing, isFalse);
      expect(handler.playbackState.value.processingState,
          AudioProcessingState.idle);
    });
  });

  group('cover art', () {
    test('is fetched once per track, not per position tick', () async {
      var lookups = 0;
      final h = FooplayerAudioHandler(
        player: player,
        artUriFor: (t) async {
          lookups++;
          return Uri.parse('file:///art/${t.contentId}.jpg');
        },
      );
      addTearDown(h.close);

      player.stage(_track('a'));
      await Future<void>.delayed(Duration.zero);
      // Several unrelated notifications, as position updates produce.
      player.notifyListeners();
      player.notifyListeners();
      await Future<void>.delayed(Duration.zero);

      expect(lookups, 1);
      expect(h.mediaItem.value!.artUri.toString(), 'file:///art/a.jpg');
    });

    test('a cover arriving late is dropped if the track moved on', () async {
      final gate = <String, Completer<Uri?>>{};
      final h = FooplayerAudioHandler(
        player: player,
        artUriFor: (t) => (gate[t.contentId] = Completer<Uri?>()).future,
      );
      addTearDown(h.close);

      player.stage(_track('a'));
      await Future<void>.delayed(Duration.zero);
      player.stage(_track('b'));
      await Future<void>.delayed(Duration.zero);

      // 'a' finally resolves, but 'b' is showing now.
      gate['a']!.complete(Uri.parse('file:///art/a.jpg'));
      await Future<void>.delayed(Duration.zero);

      expect(h.mediaItem.value!.id, 'b');
      expect(
        h.mediaItem.value!.artUri,
        isNull,
        reason: "a stale cover on the lock screen is worse than none",
      );
    });

    test('a failed lookup is not fatal', () async {
      final h = FooplayerAudioHandler(
        player: player,
        artUriFor: (t) async => null,
      );
      addTearDown(h.close);

      player.stage(_track('a'));
      await Future<void>.delayed(Duration.zero);

      expect(h.mediaItem.value!.artUri, isNull);
      expect(h.mediaItem.value!.title, 'A Song');
    });
  });
}
