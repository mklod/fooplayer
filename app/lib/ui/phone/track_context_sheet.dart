// Last modified: 2026-07-24--1837
//
// Phone track long-press context sheet (Plan 2b, task P3): the phone
// counterpart of the desktop row's right-click menu. Deliberately has NO
// "View in folder"/explorer entry -- that is a desktop-only affordance
// (there is no File Explorer on Android; the plan pins this).
import 'package:flutter/material.dart';

import '../../model/library_model.dart';
import '../../model/playlist_store.dart';
import '../../model/track.dart';
import '../playlist_dialogs.dart';
import 'track_list_page.dart' show trackSubtitle;

/// Sentinel the playlist-picker sheet pops with when "New playlist…" is
/// chosen -- a private type so it can never collide with a real playlist
/// name, however creatively one is named.
class _NewPlaylistChoice {
  const _NewPlaylistChoice();
}

const _newPlaylist = _NewPlaylistChoice();

/// Shows the phone track context sheet for [track]: a header line naming
/// the track, then "Add to playlist ▸". Choosing it opens a second sheet
/// listing every merged playlist (plus "New playlist…", which runs the
/// shared name dialog and creates before adding) and appends [track] via
/// [PlaylistStore.addTrack]. Store failures surface through the shared
/// [showPlaylistError] SnackBar path; nothing here touches the models
/// directly.
Future<void> showTrackContextSheet(
  BuildContext context, {
  required Track track,
  required LibraryModel library,
  required PlaylistStore store,
}) async {
  final subtitle = trackSubtitle(track);
  final action = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            enabled: false,
            title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: subtitle.isEmpty
                ? null
                : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const Divider(height: 1),
          ListTile(
            key: const Key('sheet-add-to-playlist'),
            leading: const Icon(Icons.playlist_add),
            title: const Text('Add to playlist'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(ctx).pop('add-to-playlist'),
          ),
        ],
      ),
    ),
  );
  if (action != 'add-to-playlist' || !context.mounted) return;

  final choice = await showModalBottomSheet<Object>(
    context: context,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final pl in library.playlists)
            ListTile(
              key: Key('sheet-playlist-${pl.name}'),
              leading: const Icon(Icons.queue_music),
              title:
                  Text(pl.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.of(ctx).pop(pl.name),
            ),
          ListTile(
            key: const Key('sheet-new-playlist'),
            leading: const Icon(Icons.add),
            title: const Text('New playlist…'),
            onTap: () => Navigator.of(ctx).pop(_newPlaylist),
          ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;

  String target;
  if (choice is _NewPlaylistChoice) {
    final name = await showPlaylistNameDialog(context, store: store);
    if (name == null || !context.mounted) return;
    try {
      await store.createPlaylist(name);
    } on PlaylistStoreException catch (e) {
      if (context.mounted) showPlaylistError(context, e);
      return;
    }
    target = name;
  } else {
    target = choice as String;
  }
  if (!context.mounted) return;
  try {
    await store.addTrack(target, track.contentId);
  } on PlaylistStoreException catch (e) {
    if (context.mounted) showPlaylistError(context, e);
  }
}
