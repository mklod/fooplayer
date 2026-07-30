// The queue, as a scratch playlist you can see and rearrange.
//
// Before this the queue was invisible and write-once: tapping a song replaced
// it wholesale, and there was no way to look at what was lined up, let alone
// change it. "Play next" is meaningless if you can't see what next is.
//
// One widget for both platforms. The phone puts it behind a drawer entry, the
// desktop behind a sidebar entry; neither needs its own copy of "drag to
// reorder, swipe or tap to remove, tap to jump".
//
// Rows carry a cover thumbnail now -- "formatted like any other playlist,
// with art showing". Same [AlbumArt] widget and the same 36px size the
// playlist view's Song cell uses (track_list.dart's _SongCell), so a track
// looks like the same track whichever list it is seen in.
//
// Last modified: 2026-07-30--0200

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../artwork/artwork_resolver.dart';
import '../model/track.dart';
import '../player/player_service.dart';
import 'app_theme.dart';
import 'now_playing_bar.dart' show AlbumArt;

/// Matches track_list.dart's _kPlaylistArtSize -- not shared directly (that
/// one is private to the playlist table), but the same 36px so a cover reads
/// as the same size in both lists.
const double _kQueueArtSize = 36;

class QueueView extends StatelessWidget {
  final PlayerService player;

  /// Rendered above the list on the desktop, where there is room for a
  /// heading and a Clear action. The phone gets those from its AppBar.
  final bool showHeader;

  /// Resolves each row's cover the same way the playlist and library views
  /// do -- embedded art, a sidecar pick, a sibling file. Null falls back to
  /// [AlbumArt]'s own embedded-only path (widget tests that build this
  /// without one, or a host that has not wired Plan 4).
  final ArtworkResolver? artworkResolver;

  const QueueView({
    super.key,
    required this.player,
    this.showHeader = false,
    this.artworkResolver,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final queue = player.queueController.queue;
        final current = player.queueController.index;

        if (queue.isEmpty) {
          return const Center(
            key: Key('queue-empty'),
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'Nothing queued.\n\n'
                'Play a song, or long-press one for “Play next” — or select '
                'several and “Add to queue”.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: AppColors.inkSecondary),
              ),
            ),
          );
        }

        return Column(
          children: [
            if (showHeader) _header(context, queue.length, current),
            Expanded(
              child: ReorderableListView.builder(
                key: const Key('queue-list'),
                itemCount: queue.length,
                buildDefaultDragHandles: false,
                // onReorderItem, not onReorder: the older callback reports
                // the destination as an index in the list BEFORE the item is
                // removed, so every downward drag lands one slot short unless
                // the caller corrects for it. This one has already adjusted.
                onReorderItem: player.moveInQueue,
                itemBuilder: (context, i) =>
                    _row(context, queue[i], i, i == current),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _header(BuildContext context, int length, int current) {
    final remaining = length - current - 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      child: Row(
        children: [
          const Text(
            'Queue',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 10),
          Text(
            remaining == 0 ? 'nothing after this' : '$remaining to come',
            style: const TextStyle(fontSize: 12, color: AppColors.inkSecondary),
          ),
          const Spacer(),
          TextButton(
            key: const Key('queue-clear'),
            onPressed: remaining == 0 ? null : player.clearUpcoming,
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, Track track, int i, bool isCurrent) {
    return ListTile(
      key: ValueKey('queue-row-${track.contentId}-$i'),
      dense: true,
      selected: isCurrent,
      // The playing icon / drag handle stays where it was -- small, at the
      // very edge, the thing you grab or the thing that says "this one" --
      // with the cover it now introduces alongside it, same as a playlist
      // row's leading Song cell.
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          isCurrent
              ? const Icon(Icons.volume_up, size: 18, color: AppColors.accent)
              : ReorderableDragStartListener(
                  index: i,
                  child: const Icon(
                    Icons.drag_handle,
                    size: 18,
                    color: AppColors.inkSecondary,
                  ),
                ),
          const SizedBox(width: 8),
          AlbumArt(
            contentId: track.contentId,
            file: File(p.join(track.rootPath, track.relPath)),
            size: _kQueueArtSize,
            resolver: artworkResolver,
            track: track,
          ),
        ],
      ),
      title: Text(
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
          color: isCurrent ? AppColors.accent : AppColors.ink,
        ),
      ),
      subtitle: track.artist.isEmpty
          ? null
          : Text(
              track.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.inkSecondary,
              ),
            ),
      // No remove on the playing row: the audio would carry on regardless,
      // so the list would name one track while another was audible.
      trailing: isCurrent
          ? null
          : IconButton(
              key: Key('queue-remove-$i'),
              icon: const Icon(Icons.close, size: 16),
              tooltip: 'Remove from queue',
              onPressed: () => player.removeFromQueue(i),
            ),
      onTap: () => player.playQueueIndex(i),
    );
  }
}
