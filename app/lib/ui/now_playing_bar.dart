// Last modified: 2026-07-25--2115
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../artwork/artwork_resolver.dart';
import '../metadata/tags.dart';
import '../model/track.dart';
import '../player/player_service.dart';
import 'app_theme.dart';

String _fmt(Duration d) {
  final m = d.inMinutes;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// Renders the current track's cover art (or a placeholder while loading /
/// when none is present).
///
/// Two sources, chosen by what the caller supplies:
///
/// - **[resolver] + [track] given** (production, since Plan 4): the full
///   artwork resolution chain -- embedded tag art, then the album's
///   `.artwork.json` sidecar choice (user pick or auto best guess), then
///   `folder.jpg`/`cover.jpg`/`front.jpg` beside the file, then nothing.
///   The resolver caches per album key, dedupes concurrent requests, and
///   notifies when a pick changes so every visible surface refreshes.
/// - **neither given**: [loader] (embedded art only) -- the original
///   behavior, kept as the default so widget tests can inject a fake loader
///   without standing up a resolver.
///
/// Deliberately stateful: [ListenableBuilder] in [NowPlayingBar] rebuilds on
/// every position tick during playback (several times a second), so the art
/// [Future] must be created once per track -- not recreated on every parent
/// rebuild -- otherwise [FutureBuilder] resets to its waiting state each
/// tick (art flickers to the placeholder) and the source re-parses the
/// file's tags on every tick. The result is cached in [State] and only
/// re-requested when [contentId] actually changes (or the resolver reports
/// a new artwork revision).
class AlbumArt extends StatefulWidget {
  final String contentId;
  final File file;
  final Future<List<int>?> Function(File) loader;
  final double size;

  /// Full resolution chain. Null (the default) keeps the embedded-only
  /// [loader] path -- see the class doc.
  final ArtworkResolver? resolver;

  /// The track whose album key the [resolver] resolves. Required for the
  /// resolver path (artist/album drive the key); ignored otherwise.
  final Track? track;

  const AlbumArt({
    super.key,
    required this.contentId,
    required this.file,
    this.loader = readArtSafe,
    this.size = 56,
    this.resolver,
    this.track,
  });

  @override
  State<AlbumArt> createState() => _AlbumArtState();
}

class _AlbumArtState extends State<AlbumArt> {
  // The DECODED bytes are held as one stable Uint8List: building a fresh
  // Uint8List/ImageProvider per rebuild would miss Flutter's image cache and
  // re-decode (one blank frame) on every position tick. gaplessPlayback keeps
  // the previous art on screen while the next track's art loads.
  Uint8List? _bytes;

  // The exact list instance the current [_bytes] came from. The resolver
  // hands back the SAME cached instance on every hit, so an identity match
  // means "nothing changed" -- skip setState entirely and Flutter's image
  // cache is never asked to re-decode the same picture.
  List<int>? _raw;

  int _request = 0;
  int _seenRevision = 0;

  @override
  void initState() {
    super.initState();
    final resolver = widget.resolver;
    if (resolver != null) {
      _seenRevision = resolver.revision;
      resolver.addListener(_onArtworkChanged);
    }
    _load();
  }

  @override
  void didUpdateWidget(covariant AlbumArt oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.resolver, oldWidget.resolver)) {
      oldWidget.resolver?.removeListener(_onArtworkChanged);
      final resolver = widget.resolver;
      if (resolver != null) {
        _seenRevision = resolver.revision;
        resolver.addListener(_onArtworkChanged);
      }
      _load();
      return;
    }
    if (widget.contentId != oldWidget.contentId) {
      _load();
    }
  }

  @override
  void dispose() {
    // Symmetric with initState/didUpdateWidget: leaving this listener
    // attached would keep a disposed State (and its bytes) alive for as
    // long as the app-lifetime resolver does.
    widget.resolver?.removeListener(_onArtworkChanged);
    super.dispose();
  }

  /// A pick was applied/removed somewhere (picker, background best-guess
  /// pass) -- re-run the chain. The revision check keeps an unrelated
  /// notification from costing a reload.
  void _onArtworkChanged() {
    final resolver = widget.resolver;
    if (resolver == null || !mounted) return;
    if (resolver.revision == _seenRevision) return;
    _seenRevision = resolver.revision;
    _load();
  }

  void _load() {
    final req = ++_request;
    final resolver = widget.resolver;
    final track = widget.track;
    final future = (resolver != null && track != null)
        ? resolver.resolve(ArtworkRequest.forTrack(track))
        : widget.loader(widget.file);
    future.then((data) {
      if (!mounted || req != _request) return; // stale result for a prior track
      if (identical(data, _raw)) return; // unchanged -- don't force a re-decode
      setState(() {
        _raw = data;
        _bytes = data == null
            ? null
            : (data is Uint8List ? data : Uint8List.fromList(data));
      });
    }).catchError((Object _) {
      // Art is a nicety: a loader/resolver that throws leaves the
      // placeholder up rather than surfacing an unhandled future error.
    });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: bytes == null
          ? SizedBox(
              width: widget.size,
              height: widget.size,
              child: Icon(Icons.album, size: widget.size * 0.7),
            )
          : Image.memory(
              bytes,
              width: widget.size,
              height: widget.size,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              // Adversarial review finding 6: bytes that made it this far
              // (an embedded tag, a sidecar file, or a sibling image on
              // disk -- any of which could be corrupt or non-image content
              // that slipped past the store's write-time validation, e.g.
              // one written before that check existed) must fall back to
              // the placeholder on a decode failure, not Flutter's red
              // error box.
              errorBuilder: (context, error, stackTrace) => SizedBox(
                width: widget.size,
                height: widget.size,
                child: Icon(Icons.album, size: widget.size * 0.7),
              ),
            ),
    );
  }
}

/// Asset paths for the metro-style transport glyphs (Mike's original
/// foobar2000 JScript panel set, bundled under assets/icons/). Public so
/// widget tests can assert on the exact asset each button renders.
const kIconPlay = 'assets/icons/play.png';
const kIconPause = 'assets/icons/pause.png';
const kIconNext = 'assets/icons/next.png';
const kIconPrevious = 'assets/icons/previous.png';
const kIconShuffleOff = 'assets/icons/shuffle1.png';
const kIconShuffleOn = 'assets/icons/shuffle2.png';

/// One metro-style PNG glyph, sized and tinted for the now-playing bar.
///
/// The source PNGs are WHITE glyphs on transparency (verified by pixel
/// sampling -- avg opaque RGB is 255,255,255), which would be invisible
/// against the light [AppColors.barBg]; the srcIn [ColorFilter] repaints
/// every opaque pixel [AppColors.ink] so they read like the rest of the
/// bar's chrome.
class _MetroIcon extends StatelessWidget {
  final String asset;
  final double size;
  const _MetroIcon(this.asset, {this.size = 26});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      asset,
      width: size,
      height: size,
      // No runtime color/colorBlendMode: srcIn forces a saveLayer, whose
      // bounds SwiftShader (the Android emulator's software renderer)
      // paints as a faint hairline box around every glyph. The ink color
      // is baked into the PNGs instead (assets/icons/*.png).
      filterQuality: FilterQuality.medium,
    );
  }
}

/// Fixed-size prev/play/next transport controls, anchored to the bar's
/// left edge. `mainAxisSize: min` is required here: as a non-flex child of
/// the bar's outer [Row] (alongside the [Expanded] centering spacers), a
/// default-max Row would receive an unbounded main-axis constraint from its
/// parent and blow up trying to be infinitely wide.
class _Transport extends StatelessWidget {
  final PlayerService player;
  const _Transport({required this.player});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Previous',
          icon: const _MetroIcon(kIconPrevious),
          onPressed: player.previous,
        ),
        IconButton(
          tooltip: player.playing ? 'Pause' : 'Play',
          iconSize: 32,
          icon: _MetroIcon(
            player.playing ? kIconPause : kIconPlay,
            size: 32,
          ),
          onPressed: player.togglePlayPause,
        ),
        IconButton(
          tooltip: 'Next',
          icon: const _MetroIcon(kIconNext),
          onPressed: player.next,
        ),
      ],
    );
  }
}

/// Shuffle toggle + volume slider, anchored to the bar's right edge. Hidden
/// entirely by [NowPlayingBar] below the 900px narrow threshold. Same
/// `mainAxisSize: min` requirement as [_Transport].
class _VolumeGroup extends StatelessWidget {
  final PlayerService player;
  const _VolumeGroup({required this.player});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Shuffle state is conveyed by the glyph itself (shuffle2.png has
        // the "on" framing), replacing the old accent-color treatment.
        IconButton(
          tooltip: 'Shuffle',
          isSelected: player.shuffle,
          icon: _MetroIcon(
            player.shuffle ? kIconShuffleOn : kIconShuffleOff,
            size: 24,
          ),
          onPressed: player.toggleShuffle,
        ),
        const SizedBox(width: 4),
        const Icon(Icons.volume_up, size: 16, color: AppColors.inkSecondary),
        const SizedBox(width: 6),
        SizedBox(
          width: 100,
          child: Slider(
            value: player.volume,
            onChanged: player.setVolume,
          ),
        ),
      ],
    );
  }
}

/// The centered "LCD" readout: art + title/artist-album/seek. Everything
/// but the 56px art is [Expanded] so the title/artist ellipsize only when
/// the cluster itself is genuinely squeezed -- never at a fixed crop width.
///
/// The seek row's pos/total labels are wrapped in [Flexible] (not left as
/// bare non-flex [Text] children) so that even under pathological squeeze
/// (a very narrow window) the row degrades instead of overflowing: bare
/// non-flex children in a [Row] demand their full intrinsic width no matter
/// how little space is actually available, which is exactly what causes
/// "RenderFlex overflowed" failures.
class _LcdCluster extends StatelessWidget {
  final Track track;
  final File file;
  final Duration pos;
  final Duration total;
  final ValueChanged<double> onSeek;
  final ArtworkResolver? resolver;

  const _LcdCluster({
    super.key,
    required this.track,
    required this.file,
    required this.pos,
    required this.total,
    required this.onSeek,
    this.resolver,
  });

  @override
  Widget build(BuildContext context) {
    const timeStyle = TextStyle(fontSize: 10.5, color: AppColors.inkSecondary);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        AlbumArt(
          contentId: track.contentId,
          file: file,
          size: 56,
          resolver: resolver,
          track: track,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 2),
              Text(
                [track.artist, track.album]
                    .where((s) => s.isNotEmpty)
                    .join(' — '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 3),
              Row(
                children: [
                  Flexible(
                    child: Text(
                      _fmt(pos),
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      softWrap: false,
                      style: timeStyle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    flex: 6,
                    child: Slider(
                      value: total.inMilliseconds == 0
                          ? 0
                          : pos.inMilliseconds / total.inMilliseconds,
                      onChanged: (v) => onSeek(v),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      _fmt(total),
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      softWrap: false,
                      style: timeStyle,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class NowPlayingBar extends StatelessWidget {
  final PlayerService player;

  /// Artwork resolution chain (Plan 4). Null keeps the pre-Plan-4
  /// embedded-art-only behavior, which is what the widget tests that build
  /// the bar without an app-level resolver rely on.
  final ArtworkResolver? artworkResolver;

  const NowPlayingBar({
    super.key,
    required this.player,
    this.artworkResolver,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final t = player.current;
        if (t == null) return const SizedBox.shrink();
        final total = player.duration ?? Duration.zero;
        final pos = player.position > total ? total : player.position;
        return Container(
          height: 72,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: const BoxDecoration(
            color: AppColors.barBg,
            border: Border(top: BorderSide(color: AppColors.hairline)),
          ),
          // The seek/volume sliders get their visible-against-barBg
          // inactive track and accent-colored active track/thumb from the
          // app theme's global SliderThemeData -- no local override here,
          // by design: accent shows up in the bar ONLY via that track, not
          // via the LCD text (see _LcdCluster).
          child: LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < 900;
              return Row(
                children: [
                  _Transport(player: player),
                  const Expanded(child: SizedBox.shrink()),
                  Flexible(
                    flex: 3,
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 720),
                        child: _LcdCluster(
                          key: const Key('lcd'),
                          track: t,
                          file: File(p.join(t.rootPath, t.relPath)),
                          resolver: artworkResolver,
                          pos: pos,
                          total: total,
                          onSeek: (v) => player.seek(
                            Duration(
                              milliseconds: (v * total.inMilliseconds).round(),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Expanded(child: SizedBox.shrink()),
                  if (!narrow) _VolumeGroup(player: player),
                ],
              );
            },
          ),
        );
      },
    );
  }
}
