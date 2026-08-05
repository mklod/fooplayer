import 'dart:async';
import 'dart:io';
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kPrimaryButton, kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../artwork/artwork_picker.dart';
import '../artwork/artwork_resolver.dart';
import '../artwork/picker_seams.dart';
import '../model/activity_model.dart';
import '../model/library_model.dart';
import '../model/playlist_store.dart';
import '../model/track.dart';
import '../metadata/tag_providers.dart';
import 'edit_tags_action.dart';
import '../player/player_service.dart';
import 'adaptive.dart';
import 'app_theme.dart';
import 'now_playing_bar.dart' show AlbumArt;
import 'playlist_dialogs.dart';

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
// #, Time and Date are fixed-width -- # left-aligned (foobar shows track
// numbers flush with Title, not right-ranged like Time/Date), Time and Date
// right-aligned, foobar-style.
//
// Every row cell (Title/Artist/Album/Time/Date) renders at the same 13px
// size and [AppColors.ink] color -- Title alone adds w600 weight to carry
// emphasis, matching the (now playing) accent-color treatment it also
// switches into (see [_TrackRow.build]). This is deliberate: an earlier
// version rendered Time/Date in a smaller, greyed-out `bodySmall` style,
// which read as visually inconsistent with the other three text columns.
const _kRowTextStyle = TextStyle(fontSize: 13, color: AppColors.ink);

/// How long a row's selection highlight takes to fade in/out. Kept very
/// short (~80ms) so single-click selection reads as immediate -- the stock
/// Material ink splash + highlight (hundreds of ms) made selection feel
/// sluggish, so [_TrackRow] disables those and animates the
/// [AppColors.selectionFill] tile color itself over this duration instead.
const Duration _kSelectionAnimationDuration = Duration(milliseconds: 80);
const double _kTrackNumberColumnWidth = 36;
const double _kDurationColumnWidth = 44;
const double _kDateColumnWidth = 82;

/// The two artwork status columns: a tick when the app has a cover for the
/// track ("Art"), and a tick when the FILE itself carries one ("Emb"). Narrow
/// on purpose -- they are at-a-glance state, not data to read.
const double _kArtColumnWidth = 34;
const int _kTitleFlex = 3;
const int _kArtistFlex = 2;
const int _kTitleArtistFlex = _kTitleFlex + _kArtistFlex;
const int _kAlbumFlex = 2;

// Playlist-view "Song" cell: a small square thumbnail (scaled down from the
// now-playing bar's compact 44px [AlbumArt] -- see now_playing_bar.dart's
// kNowPlayingArtSize/_CompactBar) to the left of the title/artist block, at
// the row's own 13px text scale rather than the bar's larger LCD cluster.
const double _kPlaylistArtSize = 36;
const double _kPlaylistArtSpacing = 8;

/// Builds the absolute Windows path (backslash-separated) `explorer.exe`
/// needs from [track]'s root + relative path -- [Track.relPath] is always
/// forward-slash (see its doc), so a plain `p.join` alone would leave those
/// un-converted.
String _windowsPathOf(Track track) =>
    p.join(track.rootPath, track.relPath).replaceAll('/', r'\');

/// Builds the exact argv for launching `explorer.exe` with [track]'s file
/// pre-selected. MUST stay two separate elements -- `/select,` and the
/// absolute backslashed path. Packing them into a single
/// `/select,C:\...path...` element breaks for any path containing spaces
/// (explorer silently ignores the argument and opens Documents instead);
/// the two-element form was live-verified to select the file correctly.
List<String> explorerArgsFor(Track track) => [
  '/select,',
  _windowsPathOf(track),
];

/// Default [TrackListView.launchExplorer]: opens File Explorer with
/// [track]'s file pre-selected, matching Explorer's own right-click ->
/// "Open file location" behavior. Fire-and-forget (mirrors how playback
/// launch errors are handled elsewhere in this file) -- a missing/renamed
/// file just means Explorer opens with nothing selected rather than
/// crashing the app, and a failed spawn is swallowed outright.
void _launchInExplorer(Track track) {
  unawaited(
    Process.run(
      'explorer.exe',
      explorerArgsFor(track),
    ).catchError((Object _) => ProcessResult(0, -1, '', '')),
  );
}

class TrackListView extends StatefulWidget {
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

  /// Backs the context menu's "Add to playlist" / "Remove from playlist"
  /// items. `HomeScreen` always forwards its own real store (which carries
  /// the real device label -- see `PlaylistStore.device`); tests substitute
  /// a spy that never touches disk, or a plain `PlaylistStore` with a
  /// throwaway device label.
  final PlaylistStore playlistStore;

  /// Backs the context menu's "Album artwork..." item (Plan 4 task A3).
  /// Null -- the default -- hides the item entirely: without a search/store
  /// implementation there is nothing honest for it to do, and a menu entry
  /// that opens an empty picker is worse than no entry.
  ///
  /// MERGE (Plan 4): build one [ArtworkServices] from A1's `searchAll` +
  /// A2's `ArtworkStore`/resolver in `main.dart` and pass it down through
  /// `home_screen.dart` -> here (and to the phone sheet), which is the one
  /// wiring change that turns the whole feature on.
  final ArtworkServices? artwork;

  /// Artwork resolution chain (Plan 4), reused for the playlist view's
  /// per-row thumbnail ([AlbumArt] via [SongCell]) -- the same instance
  /// [HomeScreen] hands to [NowPlayingBar]. Null keeps every row's thumbnail
  /// on [AlbumArt]'s embedded-only placeholder path, which is what widget
  /// tests that build the list without the artwork feature wired rely on.
  /// The library (non-playlist) view never shows a thumbnail, so this is
  /// only consulted in playlist mode.
  final ArtworkResolver? artworkResolver;

  /// Answers "does the app have a cover for this track", for the "Art"
  /// column. Injected because the answer lives in the artwork sidecars,
  /// which the list itself has no business reaching into. Defaults to the
  /// track's own embedded art only.
  final bool Function(Track track)? hasArtwork;

  /// Backs the edit dialog's "Find correct tags..." button. Null hides it --
  /// a button that opens an empty picker is worse than no button. Injected
  /// so no test opens a socket.
  final TagSearch? tagSearch;

  /// Background-work reporter, so a tag save shows in the footer while it
  /// happens rather than leaving the user wondering.
  final ActivityModel? activity;

  const TrackListView({
    super.key,
    required this.library,
    required this.player,
    this.onPlayTrack,
    this.launchExplorer = _launchInExplorer,
    required this.playlistStore,
    this.artwork,
    this.artworkResolver,
    this.hasArtwork,
    this.tagSearch,
    this.activity,
  });

  @override
  State<TrackListView> createState() => _TrackListViewState();
}

class _TrackListViewState extends State<TrackListView> {
  /// Owns keyboard focus for the track-list area so Ctrl+A
  /// ([LibraryModel.selectAll]) has somewhere to land. Grabbed on any
  /// pointer-down anywhere in the list (header or a row) via the
  /// [Listener] in [build], independent of each row's own tap/double-tap
  /// gesture recognition -- so requesting focus never interferes with
  /// click/double-click disambiguation, which needs the full
  /// [kDoubleTapTimeout] window to resolve.
  final FocusNode _focusNode = FocusNode(debugLabel: 'TrackListView');

  /// Owned so arrow-key selection moves ([_moveSelection]) can keep the
  /// newly-selected row on screen -- the ListView otherwise scrolls only by
  /// mouse.
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _play(List<Track> tracks, int index) {
    final play = widget.onPlayTrack;
    if (play != null) {
      play(tracks, index);
    } else {
      widget.player.playFrom(tracks, index);
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyA &&
        HardwareKeyboard.instance.isControlPressed) {
      widget.library.selectAll();
      return KeyEventResult.handled;
    }
    // KeyDownEvent AND KeyRepeatEvent both walk: holding the key keeps
    // moving, same as every native list control. (Reported live: with a
    // row highlighted the arrow keys did nothing at all -- only Ctrl+A was
    // ever handled here.)
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _moveSelection(1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _moveSelection(-1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Moves the selection one row in [delta]'s direction, with Explorer
  /// semantics via [LibraryModel.selectTrackClick]: a plain arrow selects
  /// the single neighboring row (and moves the range anchor there); with
  /// Shift held it extends the range from the existing anchor instead.
  ///
  /// With a multi-row selection the walk starts from its leading edge in
  /// the travel direction (bottom edge going down, top going up) -- for the
  /// normal single-row selection that IS the selected row. No selection yet
  /// selects the first (down) or last (up) visible row.
  void _moveSelection(int delta) {
    final library = widget.library;
    final tracks = library.visibleTracks;
    if (tracks.isEmpty) return;
    final ids = [for (final t in tracks) t.contentId];
    final selected = library.selectedTrackIds;
    var lo = ids.length;
    var hi = -1;
    for (var i = 0; i < ids.length; i++) {
      if (selected.contains(ids[i])) {
        if (i < lo) lo = i;
        if (i > hi) hi = i;
      }
    }
    final int next;
    if (hi < 0) {
      // Nothing (visible) selected: enter the list at the near end.
      next = delta > 0 ? 0 : ids.length - 1;
    } else {
      next = (delta > 0 ? hi + 1 : lo - 1).clamp(0, ids.length - 1);
    }
    library.selectTrackClick(
      ids[next],
      ctrl: false,
      shift: HardwareKeyboard.instance.isShiftPressed,
      visibleOrder: tracks,
    );
    _revealRow(next, tracks.length);
  }

  /// Scrolls just enough to keep row [index] fully on screen. Row extent is
  /// derived from the live scroll geometry (total content / row count --
  /// rows are uniform), so this needs no hardcoded row height.
  void _revealRow(int index, int count) {
    if (!_scrollController.hasClients || count == 0) return;
    final pos = _scrollController.position;
    final viewport = pos.viewportDimension;
    final rowHeight = (pos.maxScrollExtent + viewport) / count;
    final top = index * rowHeight;
    final bottom = top + rowHeight;
    if (top < pos.pixels) {
      _scrollController.jumpTo(top);
    } else if (bottom > pos.pixels + viewport) {
      _scrollController.jumpTo(bottom - viewport);
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = widget.library;
    final player = widget.player;
    final store = widget.playlistStore;
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _handleKeyEvent,
      child: Listener(
        onPointerDown: (_) => _focusNode.requestFocus(),
        child: ListenableBuilder(
          listenable: Listenable.merge([library, player]),
          builder: (context, _) {
            final tracks = library.visibleTracks;
            // The '#' column only earns its place when it means something
            // unambiguous: exactly one album's own track order (selected in
            // the Albums pane OR as a single album folder in the Folder pane
            // -- see LibraryModel.folderSelectionIsSingleAlbum), or a
            // playlist's curated position. Anywhere else (the full library, a
            // genre/artist filter spanning many albums, or several albums
            // selected at once) track numbers from different albums would
            // collide meaninglessly, so the column stays hidden.
            final isPlaylist = library.activePlaylist != null;
            final showTrackNumber =
                isPlaylist ||
                library.albumFilters.length == 1 ||
                library.folderSelectionIsSingleAlbum;
            return Column(
              children: [
                if (isPlaylist)
                  _PlaylistBanner(
                    name: library.activePlaylist!,
                    tracks: tracks,
                    resolver: widget.artworkResolver,
                  ),
                _TrackListHeader(
                  library: library,
                  showTrackNumber: showTrackNumber,
                  playlistMode: isPlaylist,
                ),
                Expanded(
                  child: ListView.builder(
                    controller: _scrollController,
                    itemCount: tracks.length,
                    itemBuilder: (context, i) {
                      final t = tracks[i];
                      final isCurrent =
                          player.current?.contentId == t.contentId;
                      final isSelected = library.selectedTrackIds.contains(
                        t.contentId,
                      );
                      return _TrackRow(
                        track: t,
                        isCurrent: isCurrent,
                        isSelected: isSelected,
                        // Single click: standard Explorer/foobar
                        // click/Ctrl+click/Shift+click/Ctrl+Shift+click
                        // selection semantics -- no playback. See
                        // LibraryModel.selectTrackClick.
                        onSelect: () => library.selectTrackClick(
                          t.contentId,
                          ctrl: HardwareKeyboard.instance.isControlPressed,
                          shift: HardwareKeyboard.instance.isShiftPressed,
                          visibleOrder: tracks,
                        ),
                        // Double click plays *and* selects only this row
                        // (mirrors clicking a now-playing track elsewhere in
                        // the app), regardless of any wider selection.
                        onPlay: () {
                          library.selectTrack(t.contentId);
                          _play(tracks, i);
                        },
                        launchExplorer: widget.launchExplorer,
                        library: library,
                        playlistStore: store,
                        artwork: widget.artwork,
                        tagSearch: widget.tagSearch,
                        queuePlayer: widget.player,
                        activity: widget.activity,
                        artworkResolver: widget.artworkResolver,
                        showTrackNumber: showTrackNumber,
                        playlistMode: isPlaylist,
                        hasArtwork:
                            widget.hasArtwork?.call(t) ?? t.hasEmbeddedArt,
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
        ),
      ),
    );
  }
}

/// The track-list header row.
///
/// Library (non-playlist) view: clickable Title / Artist / Album / Time /
/// Date. Clicking a label sorts [LibraryModel.visibleTracks] by that column
/// (toggling direction on a repeat click of the already-active column -- see
/// [LibraryModel.setSort]); the active column's label carries a ▲/▼ arrow in
/// [AppColors.accent] showing the current direction.
///
/// Playlist view ([playlistMode]): the distinct iTunes-style four-column
/// layout -- #, Song, Album, Time, no Date. Playlist order is curator-defined
/// ([LibraryModel.visibleTracks] preserves it and ignores [LibraryModel.sortColumn]
/// entirely for an active playlist -- see its doc), so these labels are
/// deliberately NOT sort controls: plain static text in the same header
/// typography, no arrows, no hover affordance (see [PlainHeaderLabel]).
/// The playlist view's banner: the first track's cover shown large, the
/// playlist name, and a "N tracks · MM min" summary -- the header half of
/// the iTunes-style playlist layout whose four columns follow beneath it.
///
/// A playlist has no cover of its own, so the first track's album art
/// stands in (resolved through the same chain and cache every other
/// artwork surface uses; no extra lookups).
class _PlaylistBanner extends StatelessWidget {
  final String name;
  final List<Track> tracks;
  final ArtworkResolver? resolver;

  const _PlaylistBanner({
    required this.name,
    required this.tracks,
    this.resolver,
  });

  /// "7 tracks · 56 min", omitting the duration half while tracks are still
  /// missing one (a partially-enriched library would otherwise show a total
  /// that silently grows as tags load).
  String get _summary {
    final count = tracks.length;
    final label = count == 1 ? '1 track' : '$count tracks';
    if (tracks.isEmpty || tracks.any((t) => t.durationMs == null)) {
      return label;
    }
    final totalMs = tracks.fold<int>(0, (sum, t) => sum + (t.durationMs ?? 0));
    final minutes = (totalMs / 60000).round();
    if (minutes < 60) return '$label · $minutes min';
    final hours = minutes ~/ 60;
    final rem = minutes % 60;
    return '$label · ${hours}h ${rem}min';
  }

  @override
  Widget build(BuildContext context) {
    final first = tracks.isEmpty ? null : tracks.first;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (first != null)
            AlbumArt(
              key: const Key('playlist-banner-art'),
              contentId: first.contentId,
              file: File(p.join(first.rootPath, first.relPath)),
              size: 96,
              resolver: resolver,
              track: first,
            ),
          if (first != null) const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  key: const Key('playlist-banner-title'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppColors.ink,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _summary,
                  key: const Key('playlist-banner-summary'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TrackListHeader extends StatelessWidget {
  final LibraryModel library;
  final bool showTrackNumber;
  final bool playlistMode;

  const _TrackListHeader({
    required this.library,
    required this.showTrackNumber,
    required this.playlistMode,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.hairline)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: playlistMode ? _buildPlaylistRow() : _buildLibraryRow(),
      ),
    );
  }

  Widget _buildLibraryRow() {
    return Row(
      children: [
        if (showTrackNumber)
          SizedBox(
            width: _kTrackNumberColumnWidth,
            child: _HeaderCell(
              label: '#',
              column: SortColumn.trackNumber,
              library: library,
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
        const SizedBox(width: 32),
        SizedBox(
          width: _kDateColumnWidth,
          child: _HeaderCell(
            label: 'Date',
            column: SortColumn.dateAdded,
            library: library,
          ),
        ),
        const SizedBox(width: 8),
        const SizedBox(
          width: _kArtColumnWidth,
          child: PlainHeaderLabel(label: 'Art'),
        ),
        const SizedBox(
          width: _kArtColumnWidth,
          child: PlainHeaderLabel(label: 'Emb'),
        ),
      ],
    );
  }

  Widget _buildPlaylistRow() {
    return const Row(
      children: [
        SizedBox(
          width: _kTrackNumberColumnWidth,
          child: PlainHeaderLabel(label: '#'),
        ),
        Expanded(
          flex: _kTitleArtistFlex,
          child: PlainHeaderLabel(label: 'Song'),
        ),
        Expanded(
          flex: _kAlbumFlex,
          child: PlainHeaderLabel(label: 'Album'),
        ),
        SizedBox(width: 8),
        SizedBox(
          width: _kDurationColumnWidth,
          child: PlainHeaderLabel(label: 'Time', alignEnd: true),
        ),
      ],
    );
  }
}

/// A non-interactive header label: same typography as an inactive
/// [_HeaderCell] (quiet [AppColors.inkSecondary] labelLarge, uppercased) but
/// with no [InkWell]/hover treatment and no sort arrow -- used for the
/// playlist view's header, whose column order is curator-defined and
/// therefore not a sort control (see [_TrackListHeader]'s doc).
/// A circled check in accent blue -- the same colour the shuffle button takes
/// when it is active -- or nothing at all. Deliberately not a cross: an empty
/// cell already reads as "no", and a column of crosses beside a column of
/// ticks is noise.
class _ArtTick extends StatelessWidget {
  final bool on;
  const _ArtTick({required this.on});

  @override
  Widget build(BuildContext context) => on
      ? const Icon(
          Icons.check_circle_outline,
          size: 15,
          color: AppColors.accent,
        )
      : const SizedBox.shrink();
}

// Public (not `_PlainHeaderLabel`/`_SongCell`): queue_view.dart reuses these
// two directly so a Queue row can never drift out of visual sync with a
// playlist row again -- that drift is exactly what got reported ("the cue
// does not match the playlist view"). The column WIDTH/flex constants below
// stay private and are mirrored locally in queue_view.dart instead, since
// they're also shared with the library (non-playlist) row/header layout in
// this file and widening their reach wasn't worth the risk.
class PlainHeaderLabel extends StatelessWidget {
  final String label;
  final bool alignEnd;
  const PlainHeaderLabel({
    super.key,
    required this.label,
    this.alignEnd = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      child: Text(
        label.toUpperCase(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: alignEnd ? TextAlign.right : TextAlign.left,
        style: Theme.of(context).textTheme.labelLarge,
      ),
    );
  }
}

class _HeaderCell extends StatefulWidget {
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
  State<_HeaderCell> createState() => _HeaderCellState();
}

/// Header cells sort on click and show a pointer cursor, and that is the
/// whole of their feedback: NO hover tint, no splash, no pressed overlay.
/// Mike asked for this twice -- a grey wash sliding under the column titles
/// on every pass of the mouse reads as noise, not affordance.
class _HeaderCellState extends State<_HeaderCell> {
  @override
  Widget build(BuildContext context) {
    final label = widget.label;
    final column = widget.column;
    final library = widget.library;
    final alignEnd = widget.alignEnd;
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
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: InkWell(
        onTap: () => library.setSort(column),
        // Every Material overlay off: the InkWell is here for the tap
        // target, not for decoration.
        hoverColor: Colors.transparent,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        focusColor: Colors.transparent,
        splashFactory: NoSplash.splashFactory,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          child: Text.rich(
            TextSpan(
              children: alignEnd && active
                  ? [arrowSpan, const TextSpan(text: ' '), labelSpan]
                  : active
                  ? [labelSpan, const TextSpan(text: ' '), arrowSpan]
                  : [labelSpan],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: alignEnd ? TextAlign.right : TextAlign.left,
          ),
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
/// click plays (and selects) via [onPlay]; right click (or a long press)
/// opens a context menu (see [_showTrackContextMenu]) with a "View in
/// folder" item that invokes [launchExplorer]. [isCurrent] (playing) and
/// [isSelected] are independent -- a row can be both, either, or neither,
/// each with its own highlight: playing keeps the accent title treatment,
/// selected gets the [AppColors.selectionFill] row background.
///
/// Stateful only to remember where a finger went down, which is what
/// separates a tap from a scroll -- see [_TrackRowState._handleUp].
class _TrackRow extends StatefulWidget {
  final Track track;
  final bool isCurrent;
  final bool isSelected;
  final VoidCallback onSelect;
  final VoidCallback onPlay;
  final void Function(Track track) launchExplorer;
  // For the context menu's playlist items: the model supplies the playlist
  // list / active-playlist state, the store performs the writes.
  final LibraryModel library;
  final PlaylistStore playlistStore;
  // Null when artwork services haven't been wired -- the "Album artwork..."
  // menu item is then omitted (see [TrackListView.artwork]).
  final ArtworkServices? artwork;
  final TagSearch? tagSearch;
  final PlayerService? queuePlayer;
  final ActivityModel? activity;
  final bool showTrackNumber;
  // Precomputed by [TrackListView] (needs the row's position for playlist
  // mode, which this widget doesn't otherwise know) -- null whenever
  // [showTrackNumber] is false.
  final String? trackNumberText;
  // Selects the distinct iTunes-style four-column layout (#, Song with
  // thumbnail + title/artist, Album, Time -- see [_playlistCells]) instead
  // of the library view's five flat columns ([_libraryCells]). Only the cell
  // layout differs; the selection/InkWell/context-menu shell below is
  // shared, per TrackListView.artworkResolver's doc.
  final bool playlistMode;
  // The Song cell's thumbnail source, forwarded to [AlbumArt]. Null in
  // library mode (never consulted -- no thumbnail there) and whenever
  // [TrackListView.artworkResolver] wasn't wired, in which case [AlbumArt]
  // falls back to its own embedded-only placeholder path.
  final ArtworkResolver? artworkResolver;

  /// Whether fooplayer has a cover for this track at all -- its own embedded
  /// art, or one chosen in the artwork sidecar. Drives the "Art" column.
  final bool hasArtwork;

  const _TrackRow({
    required this.track,
    required this.isCurrent,
    required this.isSelected,
    required this.onSelect,
    required this.onPlay,
    required this.launchExplorer,
    required this.library,
    required this.playlistStore,
    required this.artwork,
    required this.showTrackNumber,
    this.trackNumberText,
    this.playlistMode = false,
    this.hasArtwork = false,
    this.artworkResolver,
    this.tagSearch,
    this.queuePlayer,
    this.activity,
  });

  @override
  State<_TrackRow> createState() => _TrackRowState();
}

class _TrackRowState extends State<_TrackRow> {
  /// Where the current press started, and whether it has since travelled far
  /// enough to be a scroll rather than a tap. Null between gestures.
  Offset? _downAt;
  bool _dragged = false;

  void _handleDown(PointerDownEvent event) {
    if (event.buttons != kPrimaryButton) return;
    _downAt = event.position;
    _dragged = false;
    // A MOUSE still selects on press: that is Explorer/foobar behavior, and
    // it is what keeps selection instant. It used to hang off InkWell.onTap,
    // which Flutter withholds for the whole kDoubleTapTimeout window
    // (~300ms) while it decides whether a second tap is coming -- so the row
    // sat unhighlighted long enough to read as a stutter. Measured at library
    // scale, the model work behind a selection is ~5ms, so that wait WAS the
    // lag.
    if (event.kind != PointerDeviceKind.touch) widget.onSelect();
  }

  void _handleMove(PointerMoveEvent event) {
    final downAt = _downAt;
    if (downAt == null || _dragged) return;
    if ((event.position - downAt).distance > kTouchSlop) _dragged = true;
  }

  /// A finger selects on LIFT, and only if it stayed put.
  ///
  /// Selecting on press is right for a mouse and wrong for a touchscreen:
  /// every flick to scroll the library begins with a pointer-down on whatever
  /// row happens to be under the finger, so scrolling selected a track
  /// constantly -- and each one redrew the sidebar's cover preview.
  ///
  /// The test is distance, not time. [kTouchSlop] is the same threshold the
  /// enclosing scrollable uses to decide it is being dragged, so "the list
  /// would have scrolled" and "this was not a tap" are by construction the
  /// same question. A deliberate tap therefore still selects the instant the
  /// finger lifts, with no hold to wait out -- better than a timed pause,
  /// which would have made every real tap feel sticky.
  void _handleUp(PointerUpEvent event) {
    final downAt = _downAt;
    final dragged = _dragged;
    _downAt = null;
    if (downAt == null) return;
    if (event.kind != PointerDeviceKind.touch) return; // selected on press
    if (dragged) return; // that was a scroll
    widget.onSelect();
  }

  // Plain-named forwards, so the cell builders below read the same as they
  // did when this was a StatelessWidget.
  Track get track => widget.track;
  bool get isCurrent => widget.isCurrent;
  bool get isSelected => widget.isSelected;
  VoidCallback get onPlay => widget.onPlay;
  void Function(Track) get launchExplorer => widget.launchExplorer;
  LibraryModel get library => widget.library;
  PlaylistStore get playlistStore => widget.playlistStore;
  ArtworkServices? get artwork => widget.artwork;
  ArtworkResolver? get artworkResolver => widget.artworkResolver;
  TagSearch? get tagSearch => widget.tagSearch;
  PlayerService? get queuePlayer => widget.queuePlayer;
  ActivityModel? get activity => widget.activity;
  bool get showTrackNumber => widget.showTrackNumber;
  String? get trackNumberText => widget.trackNumberText;
  bool get playlistMode => widget.playlistMode;
  bool get hasArtwork => widget.hasArtwork;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Listener(
        onPointerDown: _handleDown,
        onPointerMove: _handleMove,
        onPointerUp: _handleUp,
        onPointerCancel: (_) => _downAt = null,
        // A finger has no right button, so on a tablet the row menu hangs off
        // a long press instead. onLongPressStart rather than InkWell's
        // onLongPress because the menu has to open *at* the row -- and the
        // position cannot come from the earlier pointer-down: selecting the
        // row rebuilds it, so anything stashed in this build's closures is
        // gone by the time the press completes.
        //
        // Unconditional: long-press-for-menu costs a mouse user nothing, and
        // gating it on the platform would leave a touchscreen laptop without
        // it. Double-tap-to-play still works -- a long press and a double tap
        // resolve on different signals (time held vs. a second tap).
        child: GestureDetector(
          behavior: HitTestBehavior.deferToChild,
          onLongPressStart: (details) => _showTrackContextMenu(
            context: context,
            globalPosition: details.globalPosition,
            track: track,
            launchExplorer: launchExplorer,
            library: library,
            playlistStore: playlistStore,
            artwork: artwork,
            artworkResolver: artworkResolver,
            tagSearch: tagSearch,
            player: queuePlayer,
            activity: activity,
          ),
          child: InkWell(
            onDoubleTap: onPlay,
            onSecondaryTapDown: (details) => _showTrackContextMenu(
              context: context,
              globalPosition: details.globalPosition,
              track: track,
              launchExplorer: launchExplorer,
              library: library,
              playlistStore: playlistStore,
              artwork: artwork,
              artworkResolver: artworkResolver,
              tagSearch: tagSearch,
              player: queuePlayer,
              activity: activity,
            ),
            // Every Material overlay off. The splash and pressed highlight
            // took hundreds of ms to play out, which made selection feel
            // sluggish; the hover wash then fought the selection fill on the
            // way in -- press a row and it went grey, then blue, which read
            // as a flash. The snappy [_kSelectionAnimationDuration] tile
            // colour is the only row feedback now.
            splashFactory: NoSplash.splashFactory,
            highlightColor: Colors.transparent,
            hoverColor: Colors.transparent,
            focusColor: Colors.transparent,
            // Individual rows must NOT grab keyboard focus on tap -- the
            // enclosing [TrackListView] owns one list-wide [FocusNode] so
            // Ctrl+A ([LibraryModel.selectAll]) always has somewhere to land
            // regardless of which row was last clicked; a per-row focus node
            // would otherwise steal primary focus away from it on every
            // click.
            canRequestFocus: false,
            child: AnimatedContainer(
              duration: _kSelectionAnimationDuration,
              curve: Curves.easeOut,
              color: isSelected ? AppColors.selectionFill : Colors.transparent,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Row(
                  children: playlistMode
                      ? _playlistCells(context)
                      : _libraryCells(context),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The library view's five flat columns, unchanged from before the
  /// playlist-view layout existed.
  List<Widget> _libraryCells(BuildContext context) => [
    if (showTrackNumber)
      SizedBox(
        width: _kTrackNumberColumnWidth,
        child: Text(
          trackNumberText ?? '',
          textAlign: TextAlign.left,
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
    const SizedBox(width: 32),
    SizedBox(
      width: _kDateColumnWidth,
      child: Text(
        _fmtDate(track.dateAdded),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: _kRowTextStyle,
      ),
    ),
    const SizedBox(width: 8),
    SizedBox(
      width: _kArtColumnWidth,
      child: _ArtTick(on: hasArtwork),
    ),
    SizedBox(
      width: _kArtColumnWidth,
      child: _ArtTick(on: track.hasEmbeddedArt),
    ),
  ];

  /// The playlist view's distinct four-column layout: #, Song (thumbnail +
  /// title/artist), Album, Time -- no Date (playlist order carries no
  /// "date added to library" meaning worth a column). [trackNumberText] is
  /// always the 1-based playlist position here (see [TrackListView.build]'s
  /// doc), never the tag track number.
  List<Widget> _playlistCells(BuildContext context) => [
    SizedBox(
      width: _kTrackNumberColumnWidth,
      child: Text(
        trackNumberText ?? '',
        textAlign: TextAlign.left,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: _kRowTextStyle,
      ),
    ),
    Expanded(
      flex: _kTitleArtistFlex,
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
  ];
}

/// The playlist view's "Song" cell: a small square [AlbumArt] thumbnail on
/// the left (same rounded-corner + shadow treatment the now-playing bar's
/// cover uses, scaled down to [_kPlaylistArtSize]), then a two-line block --
/// title on top, artist as smaller secondary subtext beneath. [resolver]
/// null falls back to [AlbumArt]'s own embedded-only placeholder path (see
/// [TrackListView.artworkResolver]'s doc), so this never requires a resolver
/// to render.
class SongCell extends StatelessWidget {
  final Track track;
  final bool isCurrent;
  final ArtworkResolver? resolver;
  const SongCell({
    super.key,
    required this.track,
    required this.isCurrent,
    required this.resolver,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        AlbumArt(
          contentId: track.contentId,
          file: File(p.join(track.rootPath, track.relPath)),
          size: _kPlaylistArtSize,
          resolver: resolver,
          track: track,
        ),
        const SizedBox(width: _kPlaylistArtSpacing),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: isCurrent ? AppColors.accent : AppColors.ink,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                track.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Row context-menu items. A private enum rather than a bare string keeps
/// [showMenu]'s selected value type-checked.
enum _TrackMenuAction {
  viewInFolder,
  addToPlaylist,
  removeFromPlaylist,
  albumArtwork,
  editTags,
  playNext,
  addToQueue,
}

/// Shows the row's right-click context menu at [globalPosition] (from
/// [InkWell.onSecondaryTapDown]'s [TapDownDetails.globalPosition]).
///
/// Explorer-style selection-aware targeting: if [track] is already part of
/// [LibraryModel.selectedTrackIds], the menu's playlist actions act on the
/// WHOLE selection; otherwise right-clicking an unselected row first
/// replaces the selection with just that row ([LibraryModel.selectTrack]),
/// same as Explorer/foobar, so the menu always acts on exactly what's
/// highlighted afterward.
///
/// - "View in folder" invokes [launchExplorer] with [track] specifically --
///   always single-target (opening N Explorer windows for a multi-selection
///   would be nonsensical), labelled "(this track)" when a wider selection
///   is active so that's unambiguous;
/// - "Play next" and "Add to queue" are both "put this in the queue"; the
///   first puts it directly after what is playing, the second at the end.
///   "Play next" is therefore offered for a SINGLE track only -- ten selected
///   songs cannot all play next, so on a selection the two items were two
///   names for one action;
/// - "Add to playlist" opens a follow-up menu (a poor-man's submenu, shown
///   at the same anchor) listing every merged playlist plus "New
///   playlist..." and adds every selected track -- see
///   [_showAddToPlaylistMenu];
/// - "Remove from playlist" appears only in playlist view (an active
///   playlist) and removes every selected track from it, in one manifest
///   write ([PlaylistStore.removeTracks]);
/// - "Album artwork..." (Plan 4 A3) opens the shared [ArtworkPicker], search
///   anchored on [track] but a pick applied to every track in the selection
///   -- exactly the selection this menu already acts on for the other batch
///   items, so choosing a cover means what selecting ten rows and choosing
///   it looks like it should mean. Deliberately NOT inferred from a shared
///   album tag: the app cannot tell a real album from a label someone used
///   as a shortcut, so it goes by what was explicitly selected instead.
///   Shown only when [artwork] services were injected.
///
/// Store refusals ([PlaylistStoreException] -- e.g. the target playlist
/// lives in another root's manifest) surface via SnackBar, never silently;
/// successful batch adds/removes report how many tracks were affected the
/// same way.
Future<void> _showTrackContextMenu({
  required BuildContext context,
  required Offset globalPosition,
  required Track track,
  required void Function(Track track) launchExplorer,
  required LibraryModel library,
  required PlaylistStore playlistStore,
  ArtworkServices? artwork,
  ArtworkResolver? artworkResolver,
  TagSearch? tagSearch,
  PlayerService? player,
  ActivityModel? activity,
}) async {
  // Captured BEFORE the popup menu opens (and reused by every action below,
  // including the one-more-popup-menu-deep _showAddToPlaylistMenu) so a
  // later store-error report never depends on this row's own BuildContext
  // still being mounted -- see showPlaylistError's doc.
  final messenger = ScaffoldMessenger.of(context);
  if (!library.selectedTrackIds.contains(track.contentId)) {
    library.selectTrack(track.contentId);
  }
  final selectedIds = library.selectedTrackIds;
  final selectedTracks = library.visibleTracks
      .where((t) => selectedIds.contains(t.contentId))
      .toList();
  // Defensive fallback: the right-clicked track should always end up in
  // selectedTracks (either it was already selected, or the line above just
  // selected it), but if selection and the visible list ever disagree,
  // still act on at least the row the user actually clicked.
  final tracks = selectedTracks.isNotEmpty ? selectedTracks : [track];
  final multi = tracks.length > 1;
  final n = tracks.length;

  final overlayBox =
      Overlay.of(context).context.findRenderObject() as RenderBox;
  final activePlaylist = library.activePlaylist;
  final selection = await showMenu<_TrackMenuAction>(
    context: context,
    // Right-click menus open instantly -- the default scale/fade makes a
    // menu that should feel like part of the click feel laggy.
    popUpAnimationStyle: AnimationStyle.noAnimation,
    position: RelativeRect.fromRect(
      globalPosition & const Size(1, 1),
      Offset.zero & overlayBox.size,
    ),
    items: [
      // Artwork sits at the top: it's the item reached for most often, and
      // the one worth hitting without reading the menu.
      if (artwork != null)
        PopupMenuItem(
          value: _TrackMenuAction.albumArtwork,
          child: Text(
            multi ? 'Album artwork... ($n tracks)' : 'Album artwork...',
          ),
        ),
      // "Play next" IS "add to the queue, at the front" -- and that only
      // means something for one track. Ten songs cannot all play next, so
      // offering it alongside "Add to queue" for a selection was two names
      // for the same thing with no way to tell them apart. A multi-selection
      // gets the one action that reads true.
      if (!multi)
        const PopupMenuItem(
          value: _TrackMenuAction.playNext,
          child: Text('Play next'),
        ),
      PopupMenuItem(
        value: _TrackMenuAction.addToQueue,
        child: Text(multi ? 'Add to queue ($n tracks)' : 'Add to queue'),
      ),
      PopupMenuItem(
        value: _TrackMenuAction.editTags,
        child: Text(multi ? 'Edit tags... ($n tracks)' : 'Edit tags...'),
      ),
      // Shells out to explorer.exe, so it is offered only where that
      // exists. The panel layout runs on a tablet now, where this would be
      // a menu item that silently does nothing.
      if (hasFileExplorer)
        PopupMenuItem(
          value: _TrackMenuAction.viewInFolder,
          child: Text(multi ? 'View in folder (this track)' : 'View in folder'),
        ),
      const PopupMenuItem(
        value: _TrackMenuAction.addToPlaylist,
        child: Text('Add to playlist ▸'),
      ),
      if (activePlaylist != null)
        const PopupMenuItem(
          value: _TrackMenuAction.removeFromPlaylist,
          child: Text('Remove from playlist'),
        ),
    ],
  );
  if (!context.mounted) return;
  switch (selection) {
    case _TrackMenuAction.playNext:
      await player?.playNext(tracks);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            multi ? 'Playing next: $n tracks' : 'Playing next: ${track.title}',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    case _TrackMenuAction.addToQueue:
      await player?.addToQueue(tracks);
      messenger.showSnackBar(
        SnackBar(
          content: Text(multi ? 'Queued $n tracks' : 'Queued: ${track.title}'),
          duration: const Duration(seconds: 2),
        ),
      );
    case _TrackMenuAction.editTags:
      await editTrackTags(
        context: context,
        messenger: messenger,
        tracks: tracks,
        library: library,
        search: tagSearch,
        activity: activity,
      );
    case _TrackMenuAction.viewInFolder:
      launchExplorer(track);
    case _TrackMenuAction.addToPlaylist:
      await _showAddToPlaylistMenu(
        context: context,
        messenger: messenger,
        globalPosition: globalPosition,
        tracks: tracks,
        library: library,
        playlistStore: playlistStore,
      );
    case _TrackMenuAction.removeFromPlaylist:
      if (activePlaylist == null) return; // unreachable; item not shown
      try {
        final removed = await playlistStore.removeTracks(activePlaylist, [
          for (final t in tracks) t.contentId,
        ]);
        showPlaylistInfo(
          messenger,
          removed == 1
              ? 'Removed 1 track from the playlist'
              : 'Removed $removed tracks from the playlist',
        );
      } on PlaylistStoreException catch (e) {
        showPlaylistError(messenger, e);
      }
    case _TrackMenuAction.albumArtwork:
      if (artwork == null) return; // unreachable; item not shown
      await showArtworkPickerDialog(
        context,
        track: track,
        services: artwork,
        resolver: artworkResolver,
        // The rest of the selection, so a pick made searching on [track]
        // still lands on every row the user actually highlighted -- not on
        // whatever else happens to share its album tag.
        otherTracks: [
          for (final t in tracks)
            if (t.contentId != track.contentId) t,
        ],
      );
    case null:
      return;
  }
}

/// The "Add to playlist" follow-up menu: every merged playlist by display
/// name, then "New playlist..." (which runs the shared name dialog, creates
/// the playlist, and adds every one of [tracks] to it in one flow). Values
/// are indices into the captured playlist list (-1 for "new") so a playlist
/// literally named "New playlist..." can't be confused with the affordance.
/// Adding is always a single manifest write for the whole batch
/// ([PlaylistStore.addTracks]), and reports how many tracks were actually
/// appended (a track already in the target playlist doesn't count twice).
Future<void> _showAddToPlaylistMenu({
  required BuildContext context,
  required ScaffoldMessengerState messenger,
  required Offset globalPosition,
  required List<Track> tracks,
  required LibraryModel library,
  required PlaylistStore playlistStore,
}) async {
  final overlayBox =
      Overlay.of(context).context.findRenderObject() as RenderBox;
  final playlists = library.playlists;
  final choice = await showMenu<int>(
    context: context,
    popUpAnimationStyle: AnimationStyle.noAnimation,
    position: RelativeRect.fromRect(
      globalPosition & const Size(1, 1),
      Offset.zero & overlayBox.size,
    ),
    items: [
      for (var i = 0; i < playlists.length; i++)
        PopupMenuItem(value: i, child: Text(playlists[i].name)),
      if (playlists.isNotEmpty) const PopupMenuDivider(),
      const PopupMenuItem(value: -1, child: Text('New playlist...')),
    ],
  );
  if (choice == null) return; // menu dismissed without a choice
  final ids = [for (final t in tracks) t.contentId];
  try {
    late final String playlistName;
    late final int added;
    if (choice >= 0) {
      // Existing playlist: no further context needed, so this proceeds (and
      // reports via [messenger]) even if [context] became unmounted while
      // the menu above was open.
      playlistName = playlists[choice].name;
      added = await playlistStore.addTracks(playlistName, ids);
    } else {
      // "New playlist...": genuinely needs a live context for the name
      // dialog's Navigator.
      if (!context.mounted) return;
      final name = await showPlaylistNameDialog(context, store: playlistStore);
      if (name == null) return;
      await playlistStore.createPlaylist(name);
      playlistName = name;
      added = await playlistStore.addTracks(name, ids);
    }
    showPlaylistInfo(
      messenger,
      added == 1
          ? 'Added 1 track to "$playlistName"'
          : 'Added $added tracks to "$playlistName"',
    );
  } on PlaylistStoreException catch (e) {
    showPlaylistError(messenger, e);
  }
}
