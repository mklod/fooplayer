// Sharing the speaker with the rest of the phone.
//
// libmpv, which media_kit uses on Android, plays to an audio track without
// asking Android for focus. So without this a phone call, a navigation
// prompt or another music app would simply play on top of us -- both audible
// at once. And unplugging headphones would blast the track out of the phone
// speaker, which is the one behaviour every user notices immediately.
//
// The decisions live here as a pure state machine so they can be tested. The
// platform plumbing (audio_session's streams) is a thin wiring layer in
// `attachAudioFocus`, because none of it can run in a unit test.
//
// Last modified: 2026-07-28--2350

/// What should happen to playback.
enum FocusAction {
  none,

  /// Stop, and remember we did so we can undo it.
  pause,

  /// Start again, because the thing that interrupted us has finished.
  resume,

  /// Keep playing, quietly, under a navigation prompt or notification.
  duck,

  /// Back to full volume.
  unduck,
}

/// Why the audio output is being taken away.
enum InterruptionKind {
  /// A short-lived one we are expected to duck under, not stop for.
  duck,

  /// A phone call or similar: stop, and expect to be given it back.
  transient,

  /// Another app took over for good. Stop, and do NOT come back on its
  /// account -- resuming into someone else's podcast is worse than staying
  /// stopped.
  permanent,
}

/// Decides what an interruption should do to playback.
///
/// Stateful on purpose: "should we resume?" is only answerable if you know
/// whether *we* were the one who paused. Resuming something the user paused
/// themselves -- because a notification happened to chirp -- is the bug this
/// shape exists to prevent.
class AudioFocusPolicy {
  bool _pausedByInterruption = false;
  bool _ducked = false;

  /// Exposed for the tests that care about the distinction above.
  bool get pausedByInterruption => _pausedByInterruption;
  bool get ducked => _ducked;

  FocusAction onInterruptionBegin({
    required bool playing,
    required InterruptionKind kind,
  }) {
    if (kind == InterruptionKind.duck) {
      if (!playing) return FocusAction.none;
      _ducked = true;
      return FocusAction.duck;
    }
    if (!playing) return FocusAction.none;
    // Only a transient interruption earns a resume afterwards.
    _pausedByInterruption = kind == InterruptionKind.transient;
    return FocusAction.pause;
  }

  FocusAction onInterruptionEnd() {
    if (_ducked) {
      _ducked = false;
      return FocusAction.unduck;
    }
    if (_pausedByInterruption) {
      _pausedByInterruption = false;
      return FocusAction.resume;
    }
    return FocusAction.none;
  }

  /// Headphones pulled out, bluetooth disconnected.
  ///
  /// Always a pause, never a later resume: the audio is now going to a
  /// speaker in a room, and it should not come back on by itself.
  FocusAction onBecomingNoisy({required bool playing}) {
    if (!playing) return FocusAction.none;
    _pausedByInterruption = false;
    return FocusAction.pause;
  }

  /// The user pressed play or pause themselves, which clears any claim this
  /// policy had on resuming later.
  void onUserTransport() {
    _pausedByInterruption = false;
  }
}
