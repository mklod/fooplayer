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
    future
        .then((data) {
          // stale result for a prior track
          if (!mounted || req != _request) {
            return;
          }
          // unchanged -- don't force a re-decode
          if (identical(data, _raw)) {
            return;
          }
          setState(() {
            _raw = data;
            _bytes = data == null
                ? null
                : (data is Uint8List ? data : Uint8List.fromList(data));
          });
        })
        .catchError((Object _) {
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

/// Now-playing bar geometry: a large square cover on the left, and a fixed
/// column on the right holding the (short, fat) seek bar with the transport
/// row beneath it.
const double kNowPlayingArtSize = 200;
const double kSeekColumnWidth = 440;

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

  // prev | play-pause | next | shuffle -- one row, shuffle immediately right
  // of Next per Mike's layout. Volume stays in its own group at the bar's
  // right edge.

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
          icon: _MetroIcon(player.playing ? kIconPause : kIconPlay, size: 32),
          onPressed: player.togglePlayPause,
        ),
        IconButton(
          tooltip: 'Next',
          icon: const _MetroIcon(kIconNext),
          onPressed: player.next,
        ),
        IconButton(
          tooltip: 'Shuffle',
          isSelected: player.shuffle,
          icon: _MetroIcon(
            player.shuffle ? kIconShuffleOn : kIconShuffleOff,
            size: 24,
          ),
          onPressed: player.toggleShuffle,
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
        const Icon(Icons.volume_up, size: 16, color: AppColors.inkSecondary),
        const SizedBox(width: 6),
        SizedBox(
          width: 100,
          child: Slider(value: player.volume, onChanged: player.setVolume),
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

  /// The single transport row rendered directly beneath the seek bar.
  final Widget transport;

  /// Cover edge length and seek-column width for the current window size --
  /// both shrink on narrow windows so the bar can never overflow.
  final double artSize;
  final double seekWidth;

  const _LcdCluster({
    super.key,
    required this.track,
    required this.file,
    required this.pos,
    required this.total,
    required this.onSeek,
    required this.transport,
    required this.artSize,
    required this.seekWidth,
    this.resolver,
  });

  @override
  Widget build(BuildContext context) {
    const timeStyle = TextStyle(fontSize: 11, color: AppColors.inkSecondary);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        AlbumArt(
          contentId: track.contentId,
          file: file,
          size: artSize,
          resolver: resolver,
          track: track,
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                track.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                [
                  track.artist,
                  track.album,
                ].where((s) => s.isNotEmpty).join(' — '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: AppColors.inkSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(width: 24),
        // Seek bar with the transport controls in ONE row beneath it, per
        // Mike's layout: shorter + fatter track, times flanking it, and
        // shuffle sitting immediately right of Next.
        SizedBox(
          width: seekWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(_fmt(pos), style: timeStyle),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 7,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 7,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 14,
                        ),
                      ),
                      child: Slider(
                        value: total.inMilliseconds == 0
                            ? 0
                            : pos.inMilliseconds / total.inMilliseconds,
                        onChanged: (v) => onSeek(v),
                      ),
                    ),
                  ),
                  Text(_fmt(total), style: timeStyle),
                ],
              ),
              const SizedBox(height: 2),
              transport,
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

  const NowPlayingBar({super.key, required this.player, this.artworkResolver});

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
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
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
              final w = constraints.maxWidth;
              final narrow = w < 900;
              // Shrink the cover and the seek column together as the window
              // narrows; below ~700px the layout drops to a compact bar so a
              // small window can never overflow (pinned by a widget test).
              final artSize = w >= 1100
                  ? kNowPlayingArtSize
                  : w >= 900
                  ? 140.0
                  : w >= 700
                  ? 96.0
                  : 64.0;
              final seekWidth = w >= 1100
                  ? kSeekColumnWidth
                  : (w * 0.42).clamp(220.0, kSeekColumnWidth);
              return Row(
                children: [
                  Expanded(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1200),
                        child: _LcdCluster(
                          key: const Key('lcd'),
                          track: t,
                          file: File(p.join(t.rootPath, t.relPath)),
                          resolver: artworkResolver,
                          pos: pos,
                          total: total,
                          transport: _Transport(player: player),
                          artSize: artSize,
                          seekWidth: seekWidth,
                          onSeek: (v) => player.seek(
                            Duration(
                              milliseconds: (v * total.inMilliseconds).round(),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
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
