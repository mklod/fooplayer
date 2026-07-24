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

class NowPlayingBar extends StatelessWidget {
  final PlayerService player;
  final Directory libraryRoot;
  const NowPlayingBar(
      {super.key, required this.player, required this.libraryRoot});

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
          child: Row(
            children: [
              FutureBuilder<List<int>?>(
                key: ValueKey(t.contentId),
                future: readArt(File(p.join(libraryRoot.path, t.relPath))),
                builder: (context, snap) {
                  final bytes = snap.data;
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: bytes == null
                        ? const SizedBox(
                            width: 68, height: 68, child: Icon(Icons.album, size: 48))
                        : Image.memory(Uint8List.fromList(bytes),
                            width: 68, height: 68, fit: BoxFit.cover),
                  );
                },
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 220,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text([t.artist, t.album].where((s) => s.isNotEmpty).join(' — '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              IconButton(
                  icon: const Icon(Icons.skip_previous),
                  onPressed: player.previous),
              IconButton(
                iconSize: 36,
                icon: Icon(player.playing ? Icons.pause : Icons.play_arrow),
                onPressed: player.togglePlayPause,
              ),
              IconButton(
                  icon: const Icon(Icons.skip_next), onPressed: player.next),
              IconButton(
                icon: const Icon(Icons.shuffle),
                isSelected: player.shuffle,
                color: player.shuffle
                    ? Theme.of(context).colorScheme.primary
                    : null,
                onPressed: player.toggleShuffle,
              ),
              const SizedBox(width: 8),
              Text(_fmt(pos), style: Theme.of(context).textTheme.bodySmall),
              Expanded(
                child: Slider(
                  value: total.inMilliseconds == 0
                      ? 0
                      : pos.inMilliseconds / total.inMilliseconds,
                  onChanged: (v) => player.seek(Duration(
                      milliseconds: (v * total.inMilliseconds).round())),
                ),
              ),
              Text(_fmt(total), style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(width: 8),
              const Icon(Icons.volume_up, size: 18),
              SizedBox(
                width: 120,
                child: Slider(
                    value: player.volume, onChanged: player.setVolume),
              ),
            ],
          ),
        );
      },
    );
  }
}
