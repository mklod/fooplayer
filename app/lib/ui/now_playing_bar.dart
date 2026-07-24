import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../metadata/tags.dart';
import '../player/player_service.dart';

String _fmt(Duration d) {
  final m = d.inMinutes;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// Renders the current track's embedded cover art (or a placeholder while
/// loading / when none is present).
///
/// Deliberately stateful: [ListenableBuilder] in [NowPlayingBar] rebuilds on
/// every position tick during playback (several times a second), so the art
/// [Future] must be created once per track -- not recreated on every parent
/// rebuild -- otherwise [FutureBuilder] resets to its waiting state each
/// tick (art flickers to the placeholder) and [loader] re-parses the file's
/// tags on every tick. The future is cached in [State] and only
/// re-requested when [contentId] actually changes.
class AlbumArt extends StatefulWidget {
  final String contentId;
  final File file;
  final Future<List<int>?> Function(File) loader;

  const AlbumArt({
    super.key,
    required this.contentId,
    required this.file,
    this.loader = readArt,
  });

  @override
  State<AlbumArt> createState() => _AlbumArtState();
}

class _AlbumArtState extends State<AlbumArt> {
  // The DECODED bytes are held as one stable Uint8List: building a fresh
  // Uint8List/ImageProvider per rebuild would miss Flutter's image cache and
  // re-decode (one blank frame) on every position tick. gaplessPlayback keeps
  // the previous art on screen while the next track's art loads.
  Uint8List? _bytes;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant AlbumArt oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.contentId != oldWidget.contentId) {
      _load();
    }
  }

  void _load() {
    final req = ++_request;
    widget.loader(widget.file).then((data) {
      if (!mounted || req != _request) return; // stale result for a prior track
      setState(() => _bytes = data == null ? null : Uint8List.fromList(data));
    });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: bytes == null
          ? const SizedBox(
              width: 68,
              height: 68,
              child: Icon(Icons.album, size: 48),
            )
          : Image.memory(
              bytes,
              width: 68,
              height: 68,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            ),
    );
  }
}

class NowPlayingBar extends StatelessWidget {
  final PlayerService player;
  final Directory libraryRoot;
  const NowPlayingBar({
    super.key,
    required this.player,
    required this.libraryRoot,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final t = player.current;
        if (t == null) return const SizedBox.shrink();
        final total = player.duration ?? Duration.zero;
        final pos = player.position > total ? total : player.position;
        return Container(
          height: 84,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          // The bar's background IS Material 3's default inactive-track color,
          // which renders the seek bar invisible at low progress — give the
          // sliders an explicitly visible inactive track.
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              inactiveTrackColor: Theme.of(
                context,
              ).colorScheme.onSurfaceVariant.withValues(alpha: 0.35),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 640;
                return Row(
                  children: [
                    AlbumArt(
                      contentId: t.contentId,
                      file: File(p.join(libraryRoot.path, t.relPath)),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      fit: FlexFit.loose,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 220),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              t.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              [
                                t.artist,
                                t.album,
                              ].where((s) => s.isNotEmpty).join(' — '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_previous),
                      onPressed: player.previous,
                    ),
                    IconButton(
                      iconSize: 36,
                      icon: Icon(
                        player.playing ? Icons.pause : Icons.play_arrow,
                      ),
                      onPressed: player.togglePlayPause,
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_next),
                      onPressed: player.next,
                    ),
                    IconButton(
                      icon: const Icon(Icons.shuffle),
                      isSelected: player.shuffle,
                      color: player.shuffle
                          ? Theme.of(context).colorScheme.primary
                          : null,
                      onPressed: player.toggleShuffle,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _fmt(pos),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Expanded(
                      child: Slider(
                        value: total.inMilliseconds == 0
                            ? 0
                            : pos.inMilliseconds / total.inMilliseconds,
                        onChanged: (v) => player.seek(
                          Duration(
                            milliseconds: (v * total.inMilliseconds).round(),
                          ),
                        ),
                      ),
                    ),
                    Text(
                      _fmt(total),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (!narrow) ...[
                      const SizedBox(width: 8),
                      const Icon(Icons.volume_up, size: 18),
                      SizedBox(
                        width: 120,
                        child: Slider(
                          value: player.volume,
                          onChanged: player.setVolume,
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}
