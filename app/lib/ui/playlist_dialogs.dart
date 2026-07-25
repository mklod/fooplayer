// Last modified: 2026-07-24
import 'package:flutter/material.dart';

import '../model/playlist_store.dart';

/// Shows the "New playlist" name dialog and returns the chosen (trimmed)
/// name, or null if cancelled. Validation runs against [store]'s rules
/// ([PlaylistStore.validateNewPlaylistName] -- non-empty, unique across the
/// merged playlist names including " (2)"-suffixed merge artifacts) both
/// as the user types and again on Create; the dialog never pops with an
/// invalid name. The caller still owns actually calling
/// [PlaylistStore.createPlaylist] (which re-validates against the fresh
/// on-disk manifest).
Future<String?> showPlaylistNameDialog(
  BuildContext context, {
  required PlaylistStore store,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => PlaylistNameDialog(store: store),
  );
}

class PlaylistNameDialog extends StatefulWidget {
  final PlaylistStore store;
  const PlaylistNameDialog({super.key, required this.store});

  @override
  State<PlaylistNameDialog> createState() => _PlaylistNameDialogState();
}

class _PlaylistNameDialogState extends State<PlaylistNameDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Null when the current text is a valid new-playlist name, else the
  /// user-presentable validation message.
  String? _validate(String text) {
    try {
      widget.store.validateNewPlaylistName(text);
      return null;
    } on PlaylistStoreException catch (e) {
      return e.message;
    }
  }

  void _submit() {
    final text = _controller.text;
    final error = _validate(text);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New playlist'),
      content: TextField(
        key: const Key('playlist-name-field'),
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          hintText: 'Playlist name',
          errorText: _error,
        ),
        // Live-clear/refresh the error as the user types so a fixed name
        // doesn't keep showing a stale message.
        onChanged: (text) => setState(() => _error = _validate(text)),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('playlist-name-create'),
          onPressed: _submit,
          child: const Text('Create'),
        ),
      ],
    );
  }
}

/// Confirm dialog for deleting playlist [name]; resolves true only on an
/// explicit Delete.
Future<bool> confirmDeletePlaylist(BuildContext context, String name) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete playlist?'),
      content: Text(
          'Delete "$name"? The tracks themselves are not removed from the '
          'library.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('confirm-delete-playlist'),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// Surfaces a [PlaylistStoreException]'s message (SnackBar) -- the shared
/// error path for every store call made from the UI.
void showPlaylistError(BuildContext context, PlaylistStoreException e) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
}
