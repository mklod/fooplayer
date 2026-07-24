import 'package:flutter/material.dart';
import '../model/library_model.dart';
import '../player/player_service.dart';
import 'app_theme.dart';

String _fmtDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

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
        return ListView.builder(
          itemCount: tracks.length,
          itemBuilder: (context, i) {
            final t = tracks[i];
            final isCurrent = player.current?.contentId == t.contentId;
            return ListTile(
              dense: true,
              selected: isCurrent,
              // Selected rows use the theme's selectionFill/ink pairing; the
              // currently-playing track additionally gets its title in the
              // sparingly-used accent color.
              title: Text(t.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: isCurrent ? AppColors.accent : null,
                  )),
              subtitle: Text(
                  [t.artist, t.album].where((s) => s.isNotEmpty).join(' — '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              trailing: Text(_fmtDate(t.dateAdded),
                  style: Theme.of(context).textTheme.bodySmall),
              onTap: () => player.playFrom(tracks, i),
            );
          },
        );
      },
    );
  }
}
