import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:path/path.dart' as p;
import '../model/track.dart';
import 'queue_controller.dart';

class PlayerService extends ChangeNotifier {
  final Directory libraryRoot;
  final QueueController queueController = QueueController();
  final _rng = Random();

  Player? _player; // lazy: never constructed in widget tests
  bool playing = false;
  Duration position = Duration.zero;
  Duration? duration;
  double volume = 1.0;

  PlayerService({required this.libraryRoot});

  Track? get current => queueController.current;
  bool get shuffle => queueController.shuffle;

  Player _ensurePlayer() {
    if (_player != null) return _player!;
    final player = Player();
    player.stream.position.listen((d) {
      position = d;
      notifyListeners();
    });
    player.stream.duration.listen((d) {
      duration = d;
      notifyListeners();
    });
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

  Future<void> _openCurrent() async {
    final t = queueController.current;
    if (t == null) {
      await _player?.stop();
      return;
    }
    final path = p.join(libraryRoot.path, t.relPath);
    await _ensurePlayer().open(Media(path), play: true);
    notifyListeners();
  }

  Future<void> playFrom(List<Track> tracks, int index) async {
    queueController.setQueue(tracks, index);
    await _openCurrent();
  }

  Future<void> togglePlayPause() async {
    await _player?.playOrPause();
  }

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
