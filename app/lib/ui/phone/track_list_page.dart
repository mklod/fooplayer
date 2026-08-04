// Last modified: 2026-08-04--0340
//
// Phone-shell filtered track list page (Plan 2b, task P3): the page an
// Artists/Albums/Playlists entry taps through to, plus the feed-style row
// widget the phone views share. STANDALONE of PhoneShell -- pushed as a
// full-screen route with its own AppBar, taking only the models it needs.
import 'package:flutter/material.dart';

import '../../model/library_model.dart';
import '../../model/playlist_store.dart';
import '../../model/track.dart';
import '../app_theme.dart';
import 'track_context_sheet.dart';

/// foobar-style `m:ss` (minutes not zero-padded, seconds two digits);
/// empty when [ms] is null (no known duration yet). Same convention as the
/// desktop track list's Time column.
String formatTrackDuration(int? ms) {
  if (ms == null) return '';
  final totalSeconds = ms ~/ 1000;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// The `artist — album` subtitle line the phone feed rows use: both when
/// both are known, just the non-empty one otherwise, '' when neither is.
String trackSubtitle(Track t) {
  if (t.artist.isNotEmpty && t.album.isNotEmpty) {
    return '${t.artist} — ${t.album}';
  }
  return t.artist.isNotEmpty ? t.artist : t.album;
}

/// One feed-style phone track row (per the Plan 2b spec): title
/// (bodyMedium, ink) over `artist — album` (bodySmall, secondary),
/// duration right-aligned -- sizes come from the theme's phone ramp, see
/// buildAppTheme. Tap = play (phone idiom -- not desktop's
/// select-then-double-click); long-press = the track context sheet (the
/// caller owns both gestures so tests can spy on them).
class PhoneTrackRow extends StatelessWidget {
  final Track track;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const PhoneTrackRow({
    super.key,
    required this.track,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final subtitle = trackSubtitle(track);
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    // Theme-derived (not hardcoded 13) so the phone type
                    // ramp in buildAppTheme actually reaches these rows.
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              formatTrackDuration(track.durationMs),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// A pushed full-screen page listing a filtered slice of the library
/// (one artist's tracks, one album in trackNumber order, one playlist in
/// playlist order -- see the `tracksOf` call sites in browse_views.dart).
///
/// [tracksOf] is re-evaluated on every [library] change (the page listens),
/// so background enrichment upgrading titles/durations keeps the page live,
/// same as the desktop list.
class TrackListPage extends StatelessWidget {
  final String title;
  final LibraryModel library;
  final PlaylistStore store;
  final List<Track> Function(LibraryModel library) tracksOf;

  /// Starts playback of [tracks] from [index]. Injected (rather than a
  /// PlayerService dependency) so widget tests never construct a real
  /// media_kit Player -- at merge the phone shell wires
  /// `player.playFrom` here.
  final void Function(List<Track> tracks, int index) onPlayTrack;

  const TrackListPage({
    super.key,
    required this.title,
    required this.library,
    required this.store,
    required this.tracksOf,
    required this.onPlayTrack,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        backgroundColor: AppColors.windowBg,
        foregroundColor: AppColors.ink,
      ),
      body: AnimatedBuilder(
        animation: library,
        builder: (context, _) {
          final tracks = tracksOf(library);
          return ListView.builder(
            itemCount: tracks.length,
            itemBuilder: (context, i) => PhoneTrackRow(
              track: tracks[i],
              onTap: () => onPlayTrack(tracks, i),
              onLongPress: () => showTrackContextSheet(
                context,
                track: tracks[i],
                library: library,
                store: store,
              ),
            ),
          );
        },
      ),
    );
  }
}
