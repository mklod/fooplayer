// Playback that survives the screen going off.
//
// Until now the phone app stopped being a music player the moment you locked
// the phone: no notification, no lock-screen controls, and Android free to
// kill the process. This is the piece that makes it an actual music app --
// a foreground service with transport controls, and audio focus handled so
// a phone call or another app pauses us instead of playing over the top.
//
// [PlayerService] stays the single source of truth. This handler is a
// translation layer in both directions: transport commands from the
// notification, the lock screen, a headset button or Android Auto come in
// and are forwarded to it; its state goes out as the playbackState and
// mediaItem Android renders. Deliberately NOT a second state machine --
// two of those disagreeing is how a pause button ends up showing "play"
// while sound is still coming out.
//
// Android/iOS only. On Windows nothing here is constructed (see
// `maybeStartAudioService`), because audio_service has no desktop
// implementation and the desktop already has a window to control playback
// from.
//
// Last modified: 2026-08-04--2358

import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';

import '../model/track.dart';
import 'audio_focus.dart';
import 'player_service.dart';

/// Bridges [PlayerService] to Android's media session.
class FooplayerAudioHandler extends BaseAudioHandler with SeekHandler {
  final PlayerService player;

  /// Resolves a track's cover for the lock screen, when one is available.
  /// Returns null (placeholder art) by default and in tests.
  final Future<Uri?> Function(Track track)? artUriFor;

  /// Decides what a phone call, a navigation prompt or a yanked headphone
  /// cable should do to playback. See [AudioFocusPolicy].
  final AudioFocusPolicy focus = AudioFocusPolicy();

  /// Volume to duck to, and what to come back to.
  static const double _duckedVolume = 0.3;
  double _volumeBeforeDuck = 1.0;

  FooplayerAudioHandler({required this.player, this.artUriFor}) {
    player.addListener(_publish);
    _publish();
  }

  /// The transport buttons Android draws, and which of them fit in the
  /// collapsed notification.
  ///
  /// Previous/play-pause/next, in that order, because that is the order every
  /// other music notification uses and muscle memory beats novelty here.
  List<MediaControl> _controls() => [
    MediaControl.skipToPrevious,
    if (player.playing) MediaControl.pause else MediaControl.play,
    MediaControl.skipToNext,
  ];

  void _publish() {
    playbackState.add(
      playbackState.value.copyWith(
        controls: _controls(),
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        // All three shown when collapsed: a notification you have to expand
        // to skip a track is a notification you don't use.
        androidCompactActionIndices: const [0, 1, 2],
        processingState: AudioProcessingState.ready,
        playing: player.playing,
        updatePosition: player.position,
        // Reported so the notification's own clock keeps ticking between
        // our updates rather than sitting still until the next position
        // event arrives.
        speed: player.playing ? 1.0 : 0.0,
      ),
    );

    final track = player.current;
    if (track == null) {
      mediaItem.add(null);
      return;
    }
    final previous = mediaItem.value;
    final item = MediaItem(
      id: track.contentId,
      title: track.title,
      artist: track.artist.isEmpty ? null : track.artist,
      album: track.album.isEmpty ? null : track.album,
      duration: player.duration ?? _libraryDuration(track),
      // Keep whatever art we already resolved for this track rather than
      // dropping to a placeholder on every position tick.
      artUri: previous?.id == track.contentId ? previous?.artUri : null,
    );
    mediaItem.add(item);

    if (previous?.id != track.contentId) unawaited(_resolveArt(track));
  }

  Duration? _libraryDuration(Track t) =>
      t.durationMs == null ? null : Duration(milliseconds: t.durationMs!);

  Future<void> _resolveArt(Track track) async {
    final resolve = artUriFor;
    if (resolve == null) return;
    final uri = await resolve(track);
    if (uri == null) return;
    // The track may have changed while the cover was being fetched; only
    // apply it if it is still the one showing.
    final current = mediaItem.value;
    if (current == null || current.id != track.contentId) return;
    mediaItem.add(current.copyWith(artUri: uri));
  }

  @override
  Future<void> play() {
    focus.onUserTransport();
    return player.play();
  }

  @override
  Future<void> pause() {
    focus.onUserTransport();
    return player.pause();
  }

  /// Applies whatever [AudioFocusPolicy] decided.
  Future<void> applyFocus(FocusAction action) async {
    switch (action) {
      case FocusAction.none:
        return;
      case FocusAction.pause:
        await player.pause();
      case FocusAction.resume:
        await player.play();
      case FocusAction.duck:
        _volumeBeforeDuck = player.volume;
        await player.setVolume(_duckedVolume);
      case FocusAction.unduck:
        await player.setVolume(_volumeBeforeDuck);
    }
  }

  /// Subscribes to the platform's interruption and becoming-noisy streams.
  ///
  /// Separate from the constructor so unit tests can exercise the handler
  /// without a platform channel; production calls it from
  /// [maybeStartAudioService].
  Future<void> attachAudioFocus() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    session.interruptionEventStream.listen((event) {
      final action = event.begin
          ? focus.onInterruptionBegin(
              playing: player.playing,
              kind: switch (event.type) {
                AudioInterruptionType.duck => InterruptionKind.duck,
                AudioInterruptionType.pause => InterruptionKind.transient,
                AudioInterruptionType.unknown => InterruptionKind.permanent,
              },
            )
          : focus.onInterruptionEnd();
      unawaited(applyFocus(action));
    });
    session.becomingNoisyEventStream.listen((_) {
      unawaited(applyFocus(focus.onBecomingNoisy(playing: player.playing)));
    });
  }

  @override
  Future<void> skipToNext() => player.next();

  @override
  Future<void> skipToPrevious() => player.previous();

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> stop() async {
    await player.pause();
    playbackState.add(
      playbackState.value.copyWith(
        playing: false,
        processingState: AudioProcessingState.idle,
      ),
    );
    await super.stop();
  }

  @override
  Future<void> onTaskRemoved() async {
    // Swiping the app away should stop the music, not leave a headless
    // service playing with no way back to it.
    await stop();
  }

  /// Detaches from [PlayerService]. Nothing in production calls this -- the
  /// handler lives as long as the app -- but a test that leaves a listener
  /// attached to a disposed model gets a confusing failure elsewhere.
  void close() => player.removeListener(_publish);
}

/// True when this platform has a media session worth registering with.
///
/// Windows has a window with its own transport bar and no audio_service
/// implementation; running the init there would throw on startup.
bool get audioServiceSupported => Platform.isAndroid || Platform.isIOS;

/// Starts the media session, or does nothing on a platform without one.
///
/// Returns null when unsupported, so callers can treat "no handler" as the
/// normal desktop case rather than an error.
Future<FooplayerAudioHandler?> maybeStartAudioService({
  required PlayerService player,
  Future<Uri?> Function(Track track)? artUriFor,
}) async {
  if (!audioServiceSupported) return null;
  final handler = await AudioService.init(
    builder: () => FooplayerAudioHandler(player: player, artUriFor: artUriFor),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'dev.mklod.fooplayer.playback',
      androidNotificationChannelName: 'Playback',
      // The service stays in the foreground for the WHOLE playback session,
      // including while paused. This used to be `true` ("drop out of
      // foreground on pause"), which combined with mpv's transient
      // playing=false on every EOF->next-track transition to flap the
      // service out of and back into the foreground on EVERY auto-advance
      // -- and a backgrounded app whose service just left the foreground is
      // exactly what Android's process management demotes/freezes, which
      // surfaced as "audio randomly cuts out early in the song after a
      // track switch until I hit pause/play on the notification" (that tap
      // is a MediaSession command, whose foreground-start exemption
      // restored the service). PlayerService additionally debounces the
      // transient false (see handlePlayingChange), but the service's
      // foreground status must not hang on that timing.
      androidStopForegroundOnPause: false,
      androidNotificationOngoing: false,
    ),
  );
  await handler.attachAudioFocus();
  return handler;
}
