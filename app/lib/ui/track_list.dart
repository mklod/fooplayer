import 'package:flutter/material.dart';
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
const double _kTrackNumberColumnWidth = 36;
const double _kDurationColumnWidth = 44;
const double _kDateColumnWidth = 82;
const int _kTitleFlex = 3;
const int _kArtistFlex = 2;
const int _kTitleArtistFlex = _kTitleFlex + _kArtistFlex;
const int _kAlbumFlex = 2;

class TrackListView extends StatelessWidget {
  final LibraryModel library;
  final PlayerService player;
  const TrackListView({super.key, required this.library, required this.player});

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
                  return _TrackRow(
                    track: t,
                    isCurrent: isCurrent,
                    onTap: () => player.playFrom(tracks, i),
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
            SizedBox(
              width: _kDurationColumnWidth,
              child: _HeaderCell(
                label: 'Time',
                column: SortColumn.duration,
                library: library,
                alignEnd: true,
              ),
            ),
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
/// Time and Date. Tap-to-play and the current-track highlight are unchanged
/// from before Task 6.
class _TrackRow extends StatelessWidget {
  final Track track;
  final bool isCurrent;
  final VoidCallback onTap;
  final bool showTrackNumber;
  // Precomputed by [TrackListView] (needs the row's position for playlist
  // mode, which this widget doesn't otherwise know) -- null whenever
  // [showTrackNumber] is false.
  final String? trackNumberText;
  const _TrackRow({
    required this.track,
    required this.isCurrent,
    required this.onTap,
    required this.showTrackNumber,
    this.trackNumberText,
  });

  @override
  Widget build(BuildContext context) {
    final secondaryStyle = Theme.of(context).textTheme.bodySmall;
    return Material(
      color: isCurrent ? AppColors.selectionFill : Colors.transparent,
      child: InkWell(
        onTap: onTap,
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
                    style: secondaryStyle,
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
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.ink,
                        ),
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
                  style: const TextStyle(fontSize: 13, color: AppColors.ink),
                ),
              ),
              SizedBox(
                width: _kDurationColumnWidth,
                child: Text(
                  _fmtDuration(track.durationMs),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: secondaryStyle,
                ),
              ),
              SizedBox(
                width: _kDateColumnWidth,
                child: Text(
                  _fmtDate(track.dateAdded),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: secondaryStyle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
