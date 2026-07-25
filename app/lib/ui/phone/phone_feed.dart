// Last modified: 2026-07-24--1855
import 'package:flutter/material.dart';
import '../../model/filtering.dart';
import '../../model/library_model.dart';
import '../../model/track.dart';

/// "Play this track": [tracks] is the full list the row was tapped inside
/// (it becomes the playback queue) and [index] the tapped row's position in
/// it. Production wires this to [PlayerService.playFrom]; widget tests
/// inject a spy instead (constructing a real media_kit Player needs natives
/// no test environment has).
typedef PlayTrackCallback = void Function(List<Track> tracks, int index);

/// Long-press on a feed/search row -- opens the track context sheet.
/// Production wires the real "Add to playlist / View details" sheet
/// (`track_context_sheet.dart`, closed over the library and its
/// PlaylistStore in main.dart); widget tests inject a spy.
typedef TrackLongPressCallback = void Function(
    BuildContext context, Track track);

/// `m:ss` for the feed rows' right-aligned Time value; empty string when the
/// track's duration isn't known (yet) -- matching the desktop track list's
/// blank Time cell rather than showing a fake 0:00.
String formatTrackDuration(int? ms) {
  if (ms == null) return '';
  final d = Duration(milliseconds: ms);
  final m = d.inMinutes;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// One phone track row: title (13 ink) over "artist — album" (11.5
/// inkSecondary), duration right-aligned; tap plays (phone idiom -- no
/// desktop select-then-double-click), long-press opens the context sheet.
/// The type specs come from the app theme's [ListTileThemeData], so this
/// widget adds no hardcoded styles of its own.
class PhoneTrackRow extends StatelessWidget {
  final Track track;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const PhoneTrackRow({
    super.key,
    required this.track,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final subtitle =
        [track.artist, track.album].where((s) => s.isNotEmpty).join(' — ');
    return ListTile(
      key: Key('phone-track-${track.contentId}'),
      title:
          Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(formatTrackDuration(track.durationMs),
          style: Theme.of(context).textTheme.bodySmall),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}

/// A scrollable list of [PhoneTrackRow]s over a FIXED, caller-ordered
/// [tracks] list -- the shared body of the feed view and the search page.
/// Tapping row `i` reports the whole list plus `i` (see
/// [PlayTrackCallback]), so the queue is exactly what the user was looking
/// at, in the order they saw it.
class PhoneTrackList extends StatelessWidget {
  final List<Track> tracks;
  final PlayTrackCallback onPlay;
  final TrackLongPressCallback onLongPress;

  const PhoneTrackList({
    super.key,
    required this.tracks,
    required this.onPlay,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: tracks.length,
      itemBuilder: (context, i) => PhoneTrackRow(
        track: tracks[i],
        onTap: () => onPlay(tracks, i),
        onLongPress: () => onLongPress(context, tracks[i]),
      ),
    );
  }
}

/// The phone home view: the library feed, date-added-desc (same
/// newest-first default the desktop feed launches with), live against
/// [library] so enrichment/rescan updates flow straight into the rows.
class PhoneFeedView extends StatelessWidget {
  final LibraryModel library;
  final PlayTrackCallback onPlay;
  final TrackLongPressCallback onLongPress;

  const PhoneFeedView({
    super.key,
    required this.library,
    required this.onPlay,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) => PhoneTrackList(
        tracks: sortByDateAddedDesc(library.allTracks),
        onPlay: onPlay,
        onLongPress: onLongPress,
      ),
    );
  }
}
