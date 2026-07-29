// Sharing the speaker with the rest of the phone.
//
// The decisions here are small and the consequences are loud: resume at the
// wrong moment and the phone starts playing music into a room by itself;
// fail to pause and a track plays underneath a phone call. The state matters
// because "should we resume?" is only answerable if you know whether WE were
// the one who paused.
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/player/audio_focus.dart';

void main() {
  late AudioFocusPolicy focus;
  setUp(() => focus = AudioFocusPolicy());

  group('a phone call', () {
    test('pauses us, and hands playback back afterwards', () {
      expect(
        focus.onInterruptionBegin(
          playing: true,
          kind: InterruptionKind.transient,
        ),
        FocusAction.pause,
      );
      expect(focus.onInterruptionEnd(), FocusAction.resume);
    });

    test('does not resume something we were not playing anyway', () {
      expect(
        focus.onInterruptionBegin(
          playing: false,
          kind: InterruptionKind.transient,
        ),
        FocusAction.none,
      );
      expect(focus.onInterruptionEnd(), FocusAction.none);
    });
  });

  group('another app taking over for good', () {
    test('pauses us and does NOT come back', () {
      expect(
        focus.onInterruptionBegin(
          playing: true,
          kind: InterruptionKind.permanent,
        ),
        FocusAction.pause,
      );
      expect(
        focus.onInterruptionEnd(),
        FocusAction.none,
        reason: 'resuming into someone else\'s podcast is worse than silence',
      );
    });
  });

  group('a navigation prompt', () {
    test('ducks rather than stopping the music', () {
      expect(
        focus.onInterruptionBegin(playing: true, kind: InterruptionKind.duck),
        FocusAction.duck,
      );
      expect(focus.onInterruptionEnd(), FocusAction.unduck);
    });

    test('does nothing when we are already paused', () {
      expect(
        focus.onInterruptionBegin(playing: false, kind: InterruptionKind.duck),
        FocusAction.none,
      );
      expect(focus.onInterruptionEnd(), FocusAction.none);
    });
  });

  group('headphones coming out', () {
    test('pauses, and never resumes on its own', () {
      expect(focus.onBecomingNoisy(playing: true), FocusAction.pause);
      expect(
        focus.onInterruptionEnd(),
        FocusAction.none,
        reason: 'the audio would now be going to a speaker in a room',
      );
    });

    test('is a no-op when nothing is playing', () {
      expect(focus.onBecomingNoisy(playing: false), FocusAction.none);
    });
  });

  test('a user pause during a call is not undone when the call ends', () {
    // The bug this prevents: the call pauses us, the user then decides they
    // want silence and presses pause themselves, and the call ending starts
    // the music anyway.
    focus.onInterruptionBegin(playing: true, kind: InterruptionKind.transient);
    expect(focus.pausedByInterruption, isTrue);

    focus.onUserTransport();

    expect(focus.onInterruptionEnd(), FocusAction.none);
  });

  test('two interruptions in a row do not leave a stuck claim', () {
    focus.onInterruptionBegin(playing: true, kind: InterruptionKind.transient);
    expect(focus.onInterruptionEnd(), FocusAction.resume);
    expect(focus.pausedByInterruption, isFalse);
    expect(focus.onInterruptionEnd(), FocusAction.none);
  });

  test('a duck inside a pause unducks first, then resumes', () {
    focus.onInterruptionBegin(playing: true, kind: InterruptionKind.transient);
    focus.onInterruptionBegin(playing: true, kind: InterruptionKind.duck);
    expect(focus.ducked, isTrue);

    expect(focus.onInterruptionEnd(), FocusAction.unduck);
    expect(focus.onInterruptionEnd(), FocusAction.resume);
  });
}
