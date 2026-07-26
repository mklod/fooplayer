// Last modified: 2026-07-25--2115
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../artwork/artwork_resolver.dart';
import '../../player/player_service.dart';
import '../app_theme.dart';
import '../now_playing_bar.dart' show AlbumArt, kIconPlay, kIconPause;
import 'metro_icon.dart';
import 'now_playing_page.dart';

/// Phone bottom mini-player: a 64px bar with 48px album art, title/artist,
/// and a metro play/pause button. Hidden entirely when no track is loaded.
/// Tapping anywhere on the bar (except the play/pause button, which consumes
/// its own tap) pushes [NowPlayingPage].
///
/// Standalone by design: `PhoneShell` wires it into its bottom slot at merge
/// time -- this widget only needs the [PlayerService].
class MiniPlayer extends StatelessWidget {
  final PlayerService player;

  /// Artwork resolution chain (Plan 4) -- forwarded to [AlbumArt] and on to
  /// [NowPlayingPage] so the mini-player, the full-screen page and the
  /// desktop bar all show the same resolved cover from one shared cache.
  /// Null keeps the pre-Plan-4 embedded-art-only behavior.
  final ArtworkResolver? artworkResolver;

  const MiniPlayer({super.key, required this.player, this.artworkResolver});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final t = player.current;
        if (t == null) return const SizedBox.shrink();
        return Material(
          color: AppColors.barBg,
          child: InkWell(
            onTap: () => Navigator.of(context).push(
              NowPlayingPage.route(
                player: player,
                artworkResolver: artworkResolver,
              ),
            ),
            child: Container(
              key: const Key('mini-player-bar'),
              height: 64,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: AppColors.hairline)),
              ),
              child: Row(
                children: [
                  AlbumArt(
                    contentId: t.contentId,
                    file: File(p.join(t.rootPath, t.relPath)),
                    size: 48,
                    resolver: artworkResolver,
                    track: t,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          t.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: player.playing ? 'Pause' : 'Play',
                    iconSize: 32,
                    icon: MetroIcon(
                      player.playing ? kIconPause : kIconPlay,
                      size: 32,
                    ),
                    onPressed: player.togglePlayPause,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
