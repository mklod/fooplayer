// PlayerService.handlePlayingChange: the engine's transient playing=false
// at every end-of-file (mpv reports EOF-pause BEFORE `completed` fires and
// the next open() flips it back) must never escape as a broadcast pause --
// that flicker, combined with a stop-foreground-on-pause audio service,
// was the "audio randomly cuts out after a track switch in background
// until notification pause/play" bug. A false that persists past the
// debounce is a real pause and goes out normally.
//
// Last modified: 2026-08-05--0006
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/player/player_service.dart';

void main() {
  test('transient false erased by a quick true never broadcasts a pause', () {
    fakeAsync((async) {
      final p = PlayerService();
      p.playing = true;
      var sawPause = false;
      p.addListener(() {
        if (!p.playing) sawPause = true;
      });

      // EOF flicker: false, then the next track's open() reports true well
      // inside the debounce window.
      p.handlePlayingChange(false);
      async.elapse(const Duration(milliseconds: 100));
      expect(p.playing, isTrue); // still held
      p.handlePlayingChange(true);
      async.elapse(const Duration(seconds: 2));

      expect(sawPause, isFalse);
      expect(p.playing, isTrue);
    });
  });

  test('a false that persists past the debounce is a real pause', () {
    fakeAsync((async) {
      final p = PlayerService();
      p.playing = true;
      var notifications = 0;
      p.addListener(() => notifications++);

      p.handlePlayingChange(false);
      expect(p.playing, isTrue); // not yet
      async.elapse(const Duration(seconds: 1));

      expect(p.playing, isFalse);
      expect(notifications, 1);
    });
  });

  test('true applies immediately and cancels a pending pause', () {
    fakeAsync((async) {
      final p = PlayerService();
      p.playing = false;

      p.handlePlayingChange(true);
      expect(p.playing, isTrue); // no debounce on the way up

      p.handlePlayingChange(false);
      p.handlePlayingChange(true);
      async.elapse(const Duration(seconds: 2));
      expect(p.playing, isTrue); // the cancelled timer never fired
    });
  });
}
