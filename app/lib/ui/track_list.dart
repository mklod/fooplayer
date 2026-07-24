import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../model/library_model.dart';
import '../model/track.dart';
import '../player/player_service.dart';
import 'app_theme.dart';

String _fmtDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Formats a duration in milliseconds as foobar-style `m:ss` (minutes not
/// zero-padded, seconds always two digits) -- blank when [ms] is null (no
/// known duration yet, e.g. a format whose parser couldn't determine one, or
/// a track not yet tag-enriched).
String _fmtDuration(int? ms) {
  if (ms == null) return '';
  final totalSeconds = ms ~/ 1000;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

// Column widths/flex shared between the header row and every track row so
// the two stay pixel-aligned. Title and Artist are true columns sharing one
// outer flexible block, split internally by the same _kTitleFlex/_kArtistFlex
// ratio the header uses (see _TrackRow); Album gets its own flexible block;
// #, Time and Date are fixed-width, right side of the row, foobar-style.
//
// Every row cell (Title/Artist/Album/Time/Date) renders at the same 13px
// size and [AppColors.ink] color -- Title alone adds w600 weight to carry
// emphasis, matching the (now playing) accent-color treatment it also
// switches into (see [_TrackRow.build]). This is deliberate: an earlier
// version rendered Time/Date in a smaller, greyed-out `bodySmall` style,
// which read as visually inconsistent with the other three text columns.
const _kRowTextStyle = TextStyle(fontSize: 13, color: AppColors.ink);
const double _kTrackNumberColumnWidth = 36;
const double _kDurationColumnWidth = 44;
const double _kDateColumnWidth = 82;
const int _kTitleFlex = 3;
const int _kArtistFlex = 2;
const int _kTitleArtistFlex = _kTitleFlex + _kArtistFlex;
const int _kAlbumFlex = 2;

/// Builds the absolute Windows path (backslash-separated) `explorer.exe`
/// needs from [track]'s root + relative path -- [Track.relPath] is always
/// forward-slash (see its doc), so a plain `p.join` alone would leave those
/// un-converted.
String _windowsPathOf(Track track) =>
    p.join(track.rootPath, track.relPath).replaceAll('/', r'\');

/// Default [TrackListView.launchExplorer]: opens File Explorer with
/// [track]'s file pre-selected, matching Explorer's own right-click ->
/// "Open file location" behavior. Fire-and-forget (mirrors how playback
/// launch errors are handled elsewhere in this file) -- a missing/renamed
/// file just means Explorer opens with nothing selected rather than
/// crashing the app.
void _launchInExplorer(Track track) {
  Process.run('explorer.exe', ['/select,${_windowsPathOf(track)}']);
}

class TrackListView extends StatelessWidget {
  final LibraryModel library;
  final PlayerService player;

  /// Starts playback of [tracks] from [index] -- defaults to the real
  /// [PlayerService.playFrom]. Injectable so widget tests can spy on
  /// double-click-to-play without it constructing a real (native-backed)
  /// `media_kit` Player: [PlayerService.playFrom] -> `_openCurrent` ->
  /// `_ensurePlayer` -> `Player()`, which widget tests must never trigger.
  final void Function(List<Track> tracks, int index)? onPlayTrack;

  /// Launches File Explorer with a track's file pre-selected, invoked by
  /// the row context menu's "View in folder" item -- defaults to
  /// [_launchInExplorer]. Injectable so widget tests can spy on it instead
  /// of actually shelling out.
  final void Function(Track track) launchExplorer;

  const TrackListView({
    super.key,
    required this.library,
    required this.player,
    this.onPlayTrack,
    this.launchExplorer = _launchInExplorer,
  });

  void _play(List<Track> tracks, int index) {
    final play = onPlayTrack;
    if (play != null) {
      play(tracks, index);
    } else {
      player.playFrom(tracks, index);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([library, player]),
      builder: (context, _) {
        final tracks = library.visibleTracks;
        // The '#' column only earns its place when it means something
        // unambiguous: a single album's own track order, or a playlist's
        // curated position. Anywhere else (the full library, a genre/artist
        // filter spanning many albums) track numbers from different albums
        // would collide meaninglessly, so the column stays hidden.
        final isPlaylist = library.activePlaylist != null;
        final showTrackNumber = isPlaylist || library.albumFilter != null;
        return Column(
          children: [
            _TrackListHeader(library: library, showTrackNumber: showTrackNumber),
            Expanded(
              child: ListView.builder(
                itemCount: tracks.length,
                itemBuilder: (context, i) {
                  final t = tracks[i];
                  final isCurrent = player.current?.contentId == t.contentId;
                  final isSelected = library.selectedTrackId == t.contentId;
                  return _TrackRow(
                    track: t,
                    isCurrent: isCurrent,
                    isSelected: isSelected,
                    // Single click selects only -- no playback.
                    onSelect: () => library.selectTrack(t.contentId),
                    // Double click plays *and* selects (mirrors clicking a
                    // now-playing track elsewhere in the app).
                    onPlay: () {
                      library.selectTrack(t.contentId);
                      _play(tracks, i);
                    },
                    launchExplorer: launchExplorer,
                    showTrackNumber: showTrackNumber,
                    // Playlist order is curator-defined, not tag-derived, so
                    // '#' shows where the track sits in that order (1-based)
                    // rather than its (possibly nonexistent, possibly
                    // unrelated) tag track number.
                    trackNumberText: showTrackNumber
                        ? (isPlaylist
                            ? '${i + 1}'
                            : t.trackNumber?.toString() ?? '')
                        : null,
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The clickable Title / Artist / Album / Time / Date header row. Clicking a
/// label sorts [LibraryModel.visibleTracks] by that column (toggling
/// direction on a repeat click of the already-active column -- see
/// [LibraryModel.setSort]); the active column's label carries a ▲/▼ arrow in
/// [AppColors.accent] showing the current direction.
class _TrackListHeader extends StatelessWidget {
  final LibraryModel library;
  final bool showTrackNumber;
  const _TrackListHeader({required this.library, required this.showTrackNumber});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.hairline)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            if (showTrackNumber)
              SizedBox(
                width: _kTrackNumberColumnWidth,
                child: _HeaderCell(
                  label: '#',
                  column: SortColumn.trackNumber,
                  library: library,
                  alignEnd: true,
                ),
              ),
            Expanded(
              flex: _kTitleArtistFlex,
              child: Row(
                children: [
                  Expanded(
                    flex: _kTitleFlex,
                    child: _HeaderCell(
                      label: 'Title',
                      column: SortColumn.title,
                      library: library,
                    ),
                  ),
                  Expanded(
                    flex: _kArtistFlex,
                    child: _HeaderCell(
                      label: 'Artist',
                      column: SortColumn.artist,
                      library: library,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: _kAlbumFlex,
              child: _HeaderCell(
                label: 'Album',
                column: SortColumn.album,
                library: library,
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: _kDurationColumnWidth,
              child: _HeaderCell(
                label: 'Time',
                column: SortColumn.duration,
                library: library,
                alignEnd: true,
              ),
            ),
            const SizedBox(width: 16),
            SizedBox(
              width: _kDateColumnWidth,
              child: _HeaderCell(
                label: 'Date',
                column: SortColumn.dateAdded,
                library: library,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  final String label;
  final SortColumn column;
  final LibraryModel library;
  final bool alignEnd;
  const _HeaderCell({
    required this.label,
    required this.column,
    required this.library,
    this.alignEnd = false,
  });

  @override
  Widget build(BuildContext context) {
    final active = library.sortColumn == column;
    final style = Theme.of(context).textTheme.labelLarge;
    final arrowSpan = TextSpan(
      text: library.sortAscending ? '▲' : '▼',
      style: style?.copyWith(color: AppColors.accent),
    );
    final labelSpan = TextSpan(text: label.toUpperCase(), style: style);
    // A single Text.rich (rather than a Row of separate Text widgets) so a
    // too-narrow fixed column (Time/Date) clips with an ellipsis instead of
    // throwing a hard RenderFlex overflow -- the label carries [style]'s
    // normal color throughout; only the arrow span is accent-colored.
    return InkWell(
      onTap: () => library.setSort(column),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Text.rich(
          TextSpan(children: alignEnd && active
              ? [arrowSpan, const TextSpan(text: ' '), labelSpan]
              : active
                  ? [labelSpan, const TextSpan(text: ' '), arrowSpan]
                  : [labelSpan]),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: alignEnd ? TextAlign.right : TextAlign.left,
        ),
      ),
    );
  }
}

/// A single track-list row, columns aligned with [_TrackListHeader]: Title
/// and Artist are separate columns sharing the Title+Artist flex block (same
/// internal split as the header), then Album, then fixed-width right-aligned
/// Time and Date.
///
/// Click/selection model: single click selects only ([onSelect]); double
/// click plays (and selects) via [onPlay]; right click opens a context menu
/// (see [_showTrackContextMenu]) with a "View in folder" item that invokes
/// [launchExplorer]. [isCurrent] (playing) and [isSelected] are independent
/// -- a row can be both, either, or neither, each with its own highlight:
/// playing keeps the accent title treatment, selected gets the
/// [AppColors.selectionFill] row background.
class _TrackRow extends StatelessWidget {
  final Track track;
  final bool isCurrent;
  final bool isSelected;
  final VoidCallback onSelect;
  final VoidCallback onPlay;
  final void Function(Track track) launchExplorer;
  final bool showTrackNumber;
  // Precomputed by [TrackListView] (needs the row's position for playlist
  // mode, which this widget doesn't otherwise know) -- null whenever
  // [showTrackNumber] is false.
  final String? trackNumberText;
  const _TrackRow({
    required this.track,
    required this.isCurrent,
    required this.isSelected,
    required this.onSelect,
    required this.onPlay,
    required this.launchExplorer,
    required this.showTrackNumber,
    this.trackNumberText,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isSelected ? AppColors.selectionFill : Colors.transparent,
      child: InkWell(
        onTap: onSelect,
        onDoubleTap: onPlay,
        onSecondaryTapDown: (details) => _showTrackContextMenu(
          context: context,
          globalPosition: details.globalPosition,
          track: track,
          launchExplorer: launchExplorer,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              if (showTrackNumber)
                SizedBox(
                  width: _kTrackNumberColumnWidth,
                  child: Text(
                    trackNumberText ?? '',
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _kRowTextStyle,
                  ),
                ),
              Expanded(
                flex: _kTitleArtistFlex,
                child: Row(
                  children: [
                    Expanded(
                      flex: _kTitleFlex,
                      child: Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: isCurrent ? AppColors.accent : AppColors.ink,
                        ),
                      ),
                    ),
                    Expanded(
                      flex: _kArtistFlex,
                      child: Text(
                        track.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _kRowTextStyle,
                      ),
                    ),
                  ],
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
              const SizedBox(width: 16),
              SizedBox(
                width: _kDateColumnWidth,
                child: Text(
                  _fmtDate(track.dateAdded),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _kRowTextStyle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Row context-menu items (currently just the one). A private enum rather
/// than a bare string keeps [showMenu]'s selected value type-checked.
enum _TrackMenuAction { viewInFolder }

/// Shows the row's right-click context menu at [globalPosition] (from
/// [InkWell.onSecondaryTapDown]'s [TapDownDetails.globalPosition]) and, if
/// its one item is chosen, invokes [launchExplorer] with [track].
Future<void> _showTrackContextMenu({
  required BuildContext context,
  required Offset globalPosition,
  required Track track,
  required void Function(Track track) launchExplorer,
}) async {
  final overlayBox =
      Overlay.of(context).context.findRenderObject() as RenderBox;
  final selection = await showMenu<_TrackMenuAction>(
    context: context,
    position: RelativeRect.fromRect(
      globalPosition & const Size(1, 1),
      Offset.zero & overlayBox.size,
    ),
    items: const [
      PopupMenuItem(
        value: _TrackMenuAction.viewInFolder,
        child: Text('View in folder'),
      ),
    ],
  );
  if (selection == _TrackMenuAction.viewInFolder) {
    launchExplorer(track);
  }
}
