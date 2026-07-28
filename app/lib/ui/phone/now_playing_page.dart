// Last modified: 2026-07-25--2115
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../artwork/artwork_resolver.dart';
import '../../player/player_service.dart';
import '../app_theme.dart';
import '../now_playing_bar.dart'
    show
        AlbumArt,
        kIconPlay,
        kIconPause,
        kIconNext,
        kIconPrevious,
        kIconShuffleOff,
        kIconShuffleOn;
import 'metro_icon.dart';

String _fmt(Duration d) {
  final m = d.inMinutes;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// Full-screen phone now-playing surface: large album art, centered
/// title/artist/album, seek slider with time labels, metro transport row
/// (prev 32 / play-pause 48 / next 32), and a shuffle + volume row.
///
/// Pushed from [MiniPlayer]'s tap (or anywhere else via [route]); the
/// AppBar's automatic back button pops it.
class NowPlayingPage extends StatelessWidget {
  final PlayerService player;

  /// Artwork resolution chain (Plan 4). Null keeps the pre-Plan-4
  /// embedded-art-only behavior.
  final ArtworkResolver? artworkResolver;

  const NowPlayingPage({super.key, required this.player, this.artworkResolver});

  /// Route helper so callers (MiniPlayer, future deep links) push the page
  /// identically without importing MaterialPageRoute boilerplate.
  static Route<void> route({
    required PlayerService player,
    ArtworkResolver? artworkResolver,
  }) => MaterialPageRoute<void>(
    builder: (_) =>
        NowPlayingPage(player: player, artworkResolver: artworkResolver),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.windowBg,
        title: const Text('Now Playing'),
      ),
      body: ListenableBuilder(
        listenable: player,
        builder: (context, _) {
          final t = player.current;
          if (t == null) {
            // Queue exhausted while the page is open: nothing to show.
            return const SizedBox.shrink();
          }
          final total = player.duration ?? Duration.zero;
          final pos = player.position > total ? total : player.position;
          const timeStyle = TextStyle(
            fontSize: 10.5,
            color: AppColors.inkSecondary,
          );

          return SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Per spec: large art is min(width - 48, 360).
                final artSize = math
                    .min(constraints.maxWidth - 48, 360.0)
                    .toDouble();
                // Scroll fallback: centered when everything fits (the normal
                // portrait-phone case), scrollable instead of RenderFlex-
                // overflowing when it doesn't (landscape / tiny windows).
                return SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 16,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(
                            child: AlbumArt(
                              contentId: t.contentId,
                              file: File(p.join(t.rootPath, t.relPath)),
                              size: artSize,
                              resolver: artworkResolver,
                              track: t,
                            ),
                          ),
                          const SizedBox(height: 24),
                          Text(
                            t.title,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              color: AppColors.ink,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            t.artist,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.inkSecondary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            t.album,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: AppColors.inkSecondary,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Text(
                                _fmt(pos),
                                maxLines: 1,
                                softWrap: false,
                                style: timeStyle,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Slider(
                                  key: const Key('np-seek'),
                                  value: total.inMilliseconds == 0
                                      ? 0
                                      : (pos.inMilliseconds /
                                                total.inMilliseconds)
                                            .clamp(0.0, 1.0),
                                  onChanged: (v) => player.seek(
                                    Duration(
                                      milliseconds: (v * total.inMilliseconds)
                                          .round(),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _fmt(total),
                                maxLines: 1,
                                softWrap: false,
                                style: timeStyle,
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                tooltip: 'Previous',
                                iconSize: 32,
                                icon: const MetroIcon(kIconPrevious, size: 32),
                                onPressed: player.previous,
                              ),
                              const SizedBox(width: 16),
                              IconButton(
                                tooltip: player.playing ? 'Pause' : 'Play',
                                iconSize: 48,
                                icon: MetroIcon(
                                  player.playing ? kIconPause : kIconPlay,
                                  size: 48,
                                ),
                                onPressed: player.togglePlayPause,
                              ),
                              const SizedBox(width: 16),
                              IconButton(
                                tooltip: 'Next',
                                iconSize: 32,
                                icon: const MetroIcon(kIconNext, size: 32),
                                onPressed: player.next,
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              IconButton(
                                tooltip: 'Shuffle',
                                isSelected: player.shuffle,
                                icon: MetroIcon(
                                  player.shuffle
                                      ? kIconShuffleOn
                                      : kIconShuffleOff,
                                  size: 24,
                                ),
                                onPressed: player.toggleShuffle,
                              ),
                              const SizedBox(width: 8),
                              const Icon(
                                Icons.volume_up,
                                size: 16,
                                color: AppColors.inkSecondary,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Slider(
                                  key: const Key('np-volume'),
                                  value: player.volume,
                                  onChanged: player.setVolume,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
