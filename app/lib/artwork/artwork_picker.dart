// Last modified: 2026-07-25--2214
//
// Plan 4 (Album Artwork Lookup) task A3 -- ONE picker widget, two chromes.
//
// [ArtworkPicker] is the shared body: a candidate grid (thumbnail + source
// + resolution labels, current selection marked) over four actions --
// "Choose file...", "Paste URL...", "Search again" and "Remove artwork".
// The desktop track context menu opens it in a dialog
// ([showArtworkPickerDialog]); the phone long-press sheet pushes it
// full-screen ([ArtworkPickerPage] / [pushArtworkPickerPage]). Same
// widget, same behaviour, same keys -- so one set of widget tests covers
// both surfaces.
//
// Every service is injected via [ArtworkServices] (see picker_seams.dart):
// this file performs NO network I/O, opens no native dialog of its own,
// and never touches the filesystem or the sidecar. That is what lets the
// tests drive the whole flow with fakes.
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../model/track.dart';
import '../ui/app_theme.dart';
import 'picker_seams.dart';

/// How a picker session ended -- the value its route pops with.
enum ArtworkPickerOutcome {
  /// A candidate / local file / pasted URL was stored.
  applied,

  /// "Remove artwork" cleared the album's entry.
  removed,

  /// Dismissed without changing anything.
  cancelled,
}

/// Header line for a track's picker: `Artist — Album`, falling back to the
/// title when the tags are sparse (same fallback shape the album key uses).
String artworkPickerLabelForTrack(Track track) {
  final parts = [
    track.artist,
    track.album.isEmpty ? track.title : track.album,
  ].where((s) => s.isNotEmpty).toList();
  return parts.isEmpty ? track.title : parts.join(' — ');
}

/// The shared picker body. Bounded by its parent (a sized [Dialog] on
/// desktop, a [Scaffold] body on phone) -- it fills whatever box it gets.
class ArtworkPicker extends StatefulWidget {
  /// The track the picker was opened from. Handed to every service seam
  /// because artwork storage is per LIBRARY ROOT: the album key alone can't
  /// tell the wiring which root's `.artwork.json` a choice belongs in, and
  /// two roots may legitimately hold the same album.
  final Track track;

  /// Album key every store call is made against -- computed by the caller
  /// (via [ArtworkServices.albumKey]) so the picker never re-derives it.
  final String albumKey;

  /// Human label shown above the grid.
  final String albumLabel;

  /// What the initial search (and "Search again") looks for.
  final ArtworkQuery query;

  final ArtworkServices services;

  /// Called when the session ends. Defaults to popping the enclosing route
  /// with the [ArtworkPickerOutcome] -- overridden by tests that pump the
  /// picker bare (no route to pop) and by hosts that want to stay open.
  final void Function(ArtworkPickerOutcome outcome)? onFinished;

  const ArtworkPicker({
    super.key,
    required this.track,
    required this.albumKey,
    required this.albumLabel,
    required this.query,
    required this.services,
    this.onFinished,
  });

  @override
  State<ArtworkPicker> createState() => _ArtworkPickerState();
}

class _ArtworkPickerState extends State<ArtworkPicker> {
  List<PickerCandidate> _candidates = const [];
  bool _loading = true;

  /// Set while a store call is in flight -- disables every action so a
  /// double-click can't fire two writes for one album.
  bool _busy = false;
  String? _error;

  /// Guards against a slow first search landing after "Search again"
  /// already returned (same stale-request pattern `AlbumArt` uses).
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _search();
  }

  Future<void> _search({bool forceRefresh = false}) async {
    final req = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    List<PickerCandidate> found;
    try {
      found = await widget.services.search(
        widget.track,
        widget.query,
        forceRefresh: forceRefresh,
      );
    } catch (e) {
      // Providers are supposed to degrade to [] rather than throw (plan
      // Global Constraints); if one ever does, the picker stays usable --
      // the local-file and paste-URL paths don't depend on search.
      if (!mounted || req != _request) return;
      setState(() {
        _loading = false;
        _candidates = const [];
        _error = 'Artwork search failed.';
      });
      return;
    }
    if (!mounted || req != _request) return;
    setState(() {
      _loading = false;
      _candidates = found;
    });
  }

  void _finish(ArtworkPickerOutcome outcome) {
    final cb = widget.onFinished;
    if (cb != null) {
      cb(outcome);
      return;
    }
    // maybePop, not pop: harmless no-op if this picker isn't in a route.
    Navigator.of(context).maybePop(outcome);
  }

  Future<void> _apply(ArtworkChoice choice) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.services.apply(widget.track, widget.albumKey, choice);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not save that artwork.';
      });
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _finish(ArtworkPickerOutcome.applied);
  }

  Future<void> _remove() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.services.remove(widget.track, widget.albumKey);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not remove the artwork.';
      });
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _finish(ArtworkPickerOutcome.removed);
  }

  Future<void> _chooseFile() async {
    if (_busy) return;
    final path = await widget.services.pickFile();
    if (!mounted || path == null || path.isEmpty) return;
    await _apply(ArtworkChoice(source: ArtworkSource.local, localPath: path));
  }

  Future<void> _pasteUrl() async {
    if (_busy) return;
    final url = await showArtworkUrlDialog(context);
    if (!mounted || url == null || url.isEmpty) return;
    await _apply(ArtworkChoice(source: ArtworkSource.url, url: url));
  }

  @override
  Widget build(BuildContext context) {
    final current =
        widget.services.currentSelectionId(widget.track, widget.albumKey);
    return Column(
      key: const Key('artwork-picker'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text(
            widget.albumLabel,
            key: const Key('artwork-picker-title'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.ink,
            ),
          ),
        ),
        Expanded(child: _body(current)),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _error!,
              key: const Key('artwork-picker-error'),
              style: const TextStyle(fontSize: 11.5, color: Color(0xFFD70015)),
            ),
          ),
        const SizedBox(height: 8),
        _actions(),
      ],
    );
  }

  Widget _body(String? currentId) {
    if (_loading) {
      return const Center(
        key: Key('artwork-picker-loading'),
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_candidates.isEmpty) {
      return const Center(
        child: Text(
          'No artwork found.',
          key: Key('artwork-picker-empty'),
          style: TextStyle(fontSize: 12.5, color: AppColors.inkSecondary),
        ),
      );
    }
    return GridView.builder(
      key: const Key('artwork-candidate-grid'),
      padding: const EdgeInsets.all(2),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 148,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 0.76,
      ),
      itemCount: _candidates.length,
      itemBuilder: (context, i) {
        final c = _candidates[i];
        return _CandidateTile(
          key: Key('artwork-candidate-$i'),
          candidate: c,
          isCurrent: currentId != null && currentId == c.id,
          loadThumb: widget.services.loadThumb,
          onTap: _busy
              ? null
              : () => _apply(
                  ArtworkChoice.fromCandidate(c, query: widget.query.term),
                ),
        );
      },
    );
  }

  Widget _actions() {
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 4,
      children: [
        TextButton(
          key: const Key('artwork-choose-file'),
          onPressed: _busy ? null : _chooseFile,
          child: const Text('Choose file...'),
        ),
        TextButton(
          key: const Key('artwork-paste-url'),
          onPressed: _busy ? null : _pasteUrl,
          child: const Text('Paste URL...'),
        ),
        TextButton(
          key: const Key('artwork-search-again'),
          onPressed: _busy ? null : () => _search(forceRefresh: true),
          child: const Text('Search again'),
        ),
        TextButton(
          key: const Key('artwork-remove'),
          onPressed: _busy ? null : _remove,
          child: const Text('Remove artwork'),
        ),
      ],
    );
  }
}

/// One grid tile: preview image (or a placeholder), the provider's name and
/// the image resolution. The current selection gets an accent border and a
/// check badge.
class _CandidateTile extends StatelessWidget {
  final PickerCandidate candidate;
  final bool isCurrent;
  final ArtworkThumbLoadFn loadThumb;
  final VoidCallback? onTap;

  const _CandidateTile({
    super.key,
    required this.candidate,
    required this.isCurrent,
    required this.loadThumb,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final resolution = candidate.resolutionLabel;
    return InkWell(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.panelBg,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: isCurrent ? AppColors.accent : AppColors.hairline,
                      width: isCurrent ? 2 : 1,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: _CandidateThumb(
                      url: candidate.previewUrl,
                      loadThumb: loadThumb,
                    ),
                  ),
                ),
                if (isCurrent)
                  const Align(
                    alignment: Alignment.topRight,
                    child: Padding(
                      padding: EdgeInsets.all(3),
                      child: Icon(
                        Icons.check_circle,
                        key: Key('artwork-current-marker'),
                        size: 16,
                        color: AppColors.accent,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            artworkSourceLabel(candidate.source),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: AppColors.ink),
          ),
          Text(
            resolution,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 10.5,
              color: AppColors.inkSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Preview bytes for one tile, fetched through the injected loader.
///
/// Holds the decoded bytes as one stable [Uint8List] and guards stale
/// responses with a request counter -- the same two rules `AlbumArt` in
/// `ui/now_playing_bar.dart` documents (rebuild-safe image cache hits, no
/// setState from a superseded load). With the default loader
/// ([noArtworkThumbnails]) every tile simply shows the placeholder, which
/// is exactly what tests want: no network, ever.
class _CandidateThumb extends StatefulWidget {
  final String url;
  final ArtworkThumbLoadFn loadThumb;

  const _CandidateThumb({required this.url, required this.loadThumb});

  @override
  State<_CandidateThumb> createState() => _CandidateThumbState();
}

class _CandidateThumbState extends State<_CandidateThumb> {
  Uint8List? _bytes;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _CandidateThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.url != oldWidget.url) _load();
  }

  void _load() {
    final req = ++_request;
    widget
        .loadThumb(widget.url)
        .then((data) {
          if (!mounted || req != _request) return;
          setState(() => _bytes = data);
        })
        .catchError((Object _) {
          // A failed preview is cosmetic -- the candidate stays pickable.
        });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) {
      return const Center(
        child: Icon(Icons.album, size: 28, color: AppColors.inkSecondary),
      );
    }
    return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
  }
}

/// "Paste URL..." prompt. Returns the trimmed URL, or null when cancelled
/// or left empty.
Future<String?> showArtworkUrlDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => const _ArtworkUrlDialog(),
  ).then((v) => (v == null || v.isEmpty) ? null : v);
}

/// Stateful so the [TextEditingController] is owned by the dialog's own
/// element and disposed in [State.dispose] -- i.e. after the route has
/// finished animating out. Disposing it in the `showDialog` future's
/// `.then` instead would kill the controller while the still-mounted
/// TextField is being rebuilt during the exit transition ("A
/// TextEditingController was used after being disposed").
class _ArtworkUrlDialog extends StatefulWidget {
  const _ArtworkUrlDialog();

  @override
  State<_ArtworkUrlDialog> createState() => _ArtworkUrlDialogState();
}

class _ArtworkUrlDialogState extends State<_ArtworkUrlDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('artwork-url-dialog'),
      title: const Text('Paste image URL'),
      content: TextField(
        key: const Key('artwork-url-field'),
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'https://...'),
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(
          key: const Key('artwork-url-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('artwork-url-confirm'),
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Use URL'),
        ),
      ],
    );
  }
}

/// Desktop chrome: the picker in a fixed-size dialog, opened from the track
/// row's "Album artwork..." context-menu item.
Future<ArtworkPickerOutcome?> showArtworkPickerDialog(
  BuildContext context, {
  required Track track,
  required ArtworkServices services,
}) {
  return showDialog<ArtworkPickerOutcome>(
    context: context,
    builder: (ctx) => Dialog(
      key: const Key('artwork-picker-dialog'),
      backgroundColor: AppColors.windowBg,
      child: SizedBox(
        width: 560,
        height: 480,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
          child: ArtworkPicker(
            track: track,
            albumKey: services.albumKey(track),
            albumLabel: artworkPickerLabelForTrack(track),
            query: artworkQueryForTrack(track),
            services: services,
          ),
        ),
      ),
    ),
  );
}

/// Phone chrome: the same picker, full screen, pushed from the long-press
/// sheet's "Album artwork" item.
class ArtworkPickerPage extends StatelessWidget {
  final Track track;
  final ArtworkServices services;

  const ArtworkPickerPage({
    super.key,
    required this.track,
    required this.services,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('artwork-picker-page'),
      appBar: AppBar(
        title: const Text('Album artwork'),
        backgroundColor: AppColors.windowBg,
        foregroundColor: AppColors.ink,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: ArtworkPicker(
            track: track,
            albumKey: services.albumKey(track),
            albumLabel: artworkPickerLabelForTrack(track),
            query: artworkQueryForTrack(track),
            services: services,
          ),
        ),
      ),
    );
  }
}

/// Pushes [ArtworkPickerPage] as a full-screen route.
Future<ArtworkPickerOutcome?> pushArtworkPickerPage(
  BuildContext context, {
  required Track track,
  required ArtworkServices services,
}) {
  return Navigator.of(context).push<ArtworkPickerOutcome>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ArtworkPickerPage(track: track, services: services),
    ),
  );
}
