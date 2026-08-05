// Correcting a track's tags from inside fooplayer.
//
// This library has plenty to correct: FLACs with no tags at all, "2012-11"
// sitting in album fields, filename-derived placeholders, 359 files whose
// artist frame disagreed with their album-artist frame. Until now the only
// way to fix any of it was Mp3tag -- which is what clobbered every download
// date in the first place, and started this whole project.
//
// So the promise on this dialog is the one the embed pass already keeps:
// only tag blocks are rewritten, the audio is copied verbatim so nothing
// changes identity, and the file's dates come back exactly as they were.
//
// Editing several tracks at once follows the rule every tag editor uses: a
// field the selection disagrees on shows as "(various)" and is left alone
// unless you actually type in it. Blanking a field on purpose clears it.
//
// Last modified: 2026-07-28--2130

import 'package:flutter/material.dart';

import '../artwork/tag_embed.dart';
import '../metadata/tag_candidate.dart';
import '../metadata/tag_providers.dart';
import '../model/track.dart';
import 'app_theme.dart';
import 'tag_match_dialog.dart';

/// The result of the dialog: null if cancelled, otherwise what to write.
class EditTagsDialog extends StatefulWidget {
  final List<Track> tracks;

  /// Metadata lookup seam. Null hides the "Find correct tags" button (widget
  /// tests that build the dialog without it); production passes the
  /// MusicBrainz search. Injected so no test opens a socket.
  final TagSearch? search;

  const EditTagsDialog({super.key, required this.tracks, this.search});

  @override
  State<EditTagsDialog> createState() => _EditTagsDialogState();
}

class _EditTagsDialogState extends State<EditTagsDialog> {
  late final Map<String, TextEditingController> _controllers;

  /// Fields whose value differs across the selection. Shown as "(various)"
  /// and only written if the user types something.
  late final Set<String> _various;

  static const _fields = [
    ('title', 'Title'),
    ('artist', 'Artist'),
    ('album', 'Album'),
    ('genre', 'Genre'),
    ('trackNumber', 'Track #'),
  ];

  String _valueOf(Track t, String field) => switch (field) {
    'title' => t.title,
    'artist' => t.artist,
    'album' => t.album,
    'genre' => t.genre,
    'trackNumber' => t.trackNumber?.toString() ?? '',
    _ => '',
  };

  @override
  void initState() {
    super.initState();
    _various = {};
    _controllers = {};
    for (final (field, _) in _fields) {
      final values = widget.tracks.map((t) => _valueOf(t, field)).toSet();
      if (values.length > 1) _various.add(field);
      _controllers[field] = TextEditingController(
        text: values.length == 1 ? values.first : '',
      );
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// What the user actually changed. A field left as "(various)" stays null,
  /// so each track keeps its own value.
  TagEdits _edits() {
    String? valueFor(String field) {
      final text = _controllers[field]!.text;
      if (_various.contains(field) && text.isEmpty) return null;
      final original = widget.tracks.map((t) => _valueOf(t, field)).toSet();
      if (original.length == 1 && original.first == text) return null;
      return text;
    }

    return TagEdits(
      title: valueFor('title'),
      artist: valueFor('artist'),
      album: valueFor('album'),
      genre: valueFor('genre'),
      trackNumber: valueFor('trackNumber'),
    );
  }

  /// Looks the track up and drops the chosen proposal into the fields.
  ///
  /// Deliberately fills the form rather than writing: the user still reads
  /// what changed and still presses Save. A lookup that wrote directly would
  /// be the same "something retagged my files" this project exists to undo.
  Future<void> _findMatch() async {
    final t = widget.tracks.first;
    final chosen = await showDialog<TagCandidate>(
      context: context,
      builder: (_) => TagMatchDialog(
        query: TagQuery(
          title: t.title,
          artist: t.artist,
          album: t.album,
          durationMs: t.durationMs,
        ),
        search: widget.search!,
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      _controllers['title']!.text = chosen.title;
      _controllers['artist']!.text = chosen.artist;
      if (chosen.album.isNotEmpty) _controllers['album']!.text = chosen.album;
      if (chosen.trackNumber.isNotEmpty) {
        _controllers['trackNumber']!.text = chosen.trackNumber;
      }
      // A field the proposal filled is no longer "various" -- the user has
      // chosen one value for the whole selection.
      _various.removeAll(['title', 'artist']);
      if (chosen.album.isNotEmpty) _various.remove('album');
      if (chosen.trackNumber.isNotEmpty) _various.remove('trackNumber');
    });
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.tracks.length;
    return AlertDialog(
      key: const Key('edit-tags'),
      title: Text(n == 1 ? 'Edit tags' : 'Edit tags — $n tracks'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (field, label) in _fields)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: TextField(
                    key: Key('edit-tags-$field'),
                    controller: _controllers[field],
                    decoration: InputDecoration(
                      labelText: label,
                      hintText: _various.contains(field) ? '(various)' : null,
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                'Written into the files themselves, so every other player '
                'sees the correction. The audio is never rewritten, so '
                'nothing changes identity, and each file’s dates are put '
                'back exactly as they were — the date downloaded is not '
                'touched.',
                style: TextStyle(fontSize: 12, color: AppColors.inkSecondary),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.search != null)
          TextButton(
            key: const Key('edit-tags-find'),
            onPressed: _findMatch,
            child: Text(
              n == 1 ? 'Find correct tags...' : 'Find correct tags... (first)',
            ),
          ),
        // No Spacer here: AlertDialog lays its actions out in an OverflowBar,
        // which is not a Flex, so an Expanded child throws.
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('edit-tags-save'),
          onPressed: () => Navigator.of(context).pop(_edits()),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
