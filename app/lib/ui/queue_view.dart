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
// Rows use the SAME # / Song / Album / Time grid as the playlist view --
// [SongCell] and [PlainHeaderLabel] straight from track_list.dart, not a
// look-alike copy. Reported live: "the cue does not match the playlist
// view... if you create a playlist, the formatting is different from the
// cue formatting" -- an earlier pass added the cover thumbnail but kept a
// bespoke ListTile shape (no #, no Album, no Time, no column header), which
// is exactly the mismatch a screenshot comparison caught. The leading #
// column carries a play/drag icon instead of a position number (the queue
// has no stable curated order worth numbering), and a remove button sits
// past Time -- the queue's own chrome, which a static playlist doesn't need
// inline. Every row still reserves that column's width even on the current
// row (which has no remove button), so every row's Album/Time line up.
//
// Last modified: 2026-08-05--0055

import 'package:flutter/material.dart';

import '../artwork/artwork_resolver.dart';
import '../model/track.dart';
import '../player/player_service.dart';
import 'app_theme.dart';
import 'track_list.dart' show PlainHeaderLabel, SongCell;

// Mirrors track_list.dart's private playlist-row constants (_kPlaylistArtSize
// via SongCell, _kTrackNumberColumnWidth, _kDurationColumnWidth,
// _kTitleArtistFlex, _kAlbumFlex, _kRowTextStyle) -- not shared directly
// (those stay private, see track_list.dart's note above PlainHeaderLabel),
// but the same values so a Queue row lines up column-for-column with a
// playlist row.
const double _kLeadingColumnWidth = 36;
const double _kDurationColumnWidth = 44;
const double _kRemoveColumnWidth = 32;
const int _kSongFlex = 5;
const int _kAlbumFlex = 2;
final _kRowTextStyle = TextStyle(fontSize: 13, color: AppColors.ink);

/// Matches track_list.dart's private `_fmtDuration` -- foobar-style `m:ss`,
/// blank when the duration isn't known yet.
String _fmtDuration(int? ms) {
  if (ms == null) return '';
  final totalSeconds = ms ~/ 1000;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

class QueueView extends StatefulWidget {
  final PlayerService player;

  /// Rendered above the list on the desktop, where there is room for a
  /// heading and a Clear action. The phone gets those from its AppBar.
  final bool showHeader;

  /// Resolves each row's cover the same way the playlist and library views
  /// do -- embedded art, a sidecar pick, a sibling file. Null falls back to
  /// [SongCell]'s own embedded-only path (widget tests that build this
  /// without one, or a host that has not wired Plan 4).
  final ArtworkResolver? artworkResolver;

  const QueueView({
    super.key,
    required this.player,
    this.showHeader = false,
    this.artworkResolver,
  });

  @override
  State<QueueView> createState() => _QueueViewState();
}

class _QueueViewState extends State<QueueView> {
  PlayerService get player => widget.player;
  bool get showHeader => widget.showHeader;
  ArtworkResolver? get artworkResolver => widget.artworkResolver;

  /// Owned so the view can open AT the playing track -- reported live:
  /// shuffling the whole library queues thousands of rows, and the Queue
  /// button dropped the user at row zero with the current track somewhere
  /// far below. Once, on open; after that the user owns the scroll (a
  /// track change while they are reading the list must not yank it).
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToCurrent());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Scrolls so the playing row sits at the top of the viewport. Row extent
  /// is derived from live scroll geometry (uniform rows), same technique as
  /// the track list's arrow-key reveal.
  void _jumpToCurrent() {
    if (!mounted || !_scrollController.hasClients) return;
    final queue = player.queueController.queue;
    final current = player.queueController.index;
    if (queue.isEmpty || current <= 0) return;
    final pos = _scrollController.position;
    final rowHeight =
        (pos.maxScrollExtent + pos.viewportDimension) / queue.length;
    _scrollController.jumpTo(
      (current * rowHeight).clamp(0.0, pos.maxScrollExtent),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final queue = player.queueController.queue;
        final current = player.queueController.index;

        if (queue.isEmpty) {
          return Center(
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
            _columnHeader(),
            Expanded(
              child: ReorderableListView.builder(
                key: const Key('queue-list'),
                scrollController: _scrollController,
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
            style: TextStyle(fontSize: 12, color: AppColors.inkSecondary),
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

  /// The playlist view's own #/Song/Album/Time header row (same
  /// [PlainHeaderLabel] typography), so the table beneath it reads as the
  /// same kind of table. The trailing gap matches [_kRemoveColumnWidth] so
  /// Time stays aligned with the rows below it, which reserve that width for
  /// the remove button.
  Widget _columnHeader() {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.hairline)),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: _kLeadingColumnWidth,
              child: PlainHeaderLabel(label: '#'),
            ),
            Expanded(flex: _kSongFlex, child: PlainHeaderLabel(label: 'Song')),
            Expanded(
              flex: _kAlbumFlex,
              child: PlainHeaderLabel(label: 'Album'),
            ),
            SizedBox(width: 8),
            SizedBox(
              width: _kDurationColumnWidth,
              child: PlainHeaderLabel(label: 'Time', alignEnd: true),
            ),
            SizedBox(width: _kRemoveColumnWidth),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, Track track, int i, bool isCurrent) {
    // The playing icon / drag handle stands in for the playlist's # -- the
    // queue has no stable curated position worth numbering, but the column
    // still carries a row identifier, left-aligned the same way # is.
    final leading = isCurrent
        ? Icon(Icons.volume_up, size: 18, color: AppColors.accent)
        : ReorderableDragStartListener(
            index: i,
            child: Icon(
              Icons.drag_handle,
              size: 18,
              color: AppColors.inkSecondary,
            ),
          );

    return InkWell(
      key: ValueKey('queue-row-${track.contentId}-$i'),
      onTap: () => player.playQueueIndex(i),
      splashFactory: NoSplash.splashFactory,
      hoverColor: Colors.transparent,
      highlightColor: Colors.transparent,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: isCurrent ? AppColors.selectionFill : Colors.transparent,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              SizedBox(
                width: _kLeadingColumnWidth,
                child: Align(alignment: Alignment.centerLeft, child: leading),
              ),
              Expanded(
                flex: _kSongFlex,
                child: SongCell(
                  track: track,
                  isCurrent: isCurrent,
                  resolver: artworkResolver,
                ),
              ),
              Expanded(
                flex: _kAlbumFlex,
                child: Text(
                  track.album,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _kRowTextStyle,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: _kDurationColumnWidth,
                child: Text(
                  _fmtDuration(track.durationMs),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _kRowTextStyle,
                ),
              ),
              SizedBox(
                width: _kRemoveColumnWidth,
                // No remove on the playing row: the audio would carry on
                // regardless, so the list would name one track while
                // another was audible. The slot stays reserved either way
                // so every row's Album/Time columns stay aligned.
                child: isCurrent
                    ? null
                    : IconButton(
                        key: Key('queue-remove-$i'),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        icon: const Icon(Icons.close, size: 16),
                        tooltip: 'Remove from queue',
                        onPressed: () => player.removeFromQueue(i),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
