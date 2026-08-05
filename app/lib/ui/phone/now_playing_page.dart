// Last modified: 2026-08-05--0005
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../artwork/artwork_resolver.dart';
import '../../artwork/dominant_color.dart';
import '../../artwork/picker_seams.dart' show ArtworkServices;
import '../../model/library_model.dart';
import '../../model/playlist_store.dart';
import '../../model/track.dart';
import '../../player/player_service.dart';
import '../app_theme.dart';
import '../now_playing_bar.dart'
    show
        AlbumArt,
        kIconPlayBare,
        kIconPauseBare,
        kIconNextBare,
        kIconPreviousBare,
        kIconShuffleOffBare,
        kIconShuffleOnBare;
import 'metro_icon.dart';
import 'phone_shell.dart' show PhoneView, PhoneViewInfo, phoneShellNavRequest;
import 'track_context_sheet.dart';

String _fmt(Duration d) {
  final m = d.inMinutes;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// Fallback gradient top color: used until artwork tinting resolves (or
/// when there is no art / no resolver at all). Deliberately a plain muted
/// slate -- the same family the extracted tint lands in -- so a track with
/// no cover doesn't look like a broken/different screen.
const Color _kFallbackTint = Color(0xFF2A3134);

/// Gradient bottom color: constant regardless of artwork, so the bottom of
/// the screen (seek bar, transport row) always sits on the same dark base.
const Color _kBaseTint = Color(0xFF171C1F);

/// How many resolved track tints are kept in memory (see
/// [_NowPlayingPageState._tintCache]). A phone session can flip through far
/// more tracks than this in one sitting, so it is capped rather than left to
/// grow for the app's whole lifetime.
const int _kMaxTintCacheEntries = 16;

/// Full-bleed, artwork-tinted phone Now Playing screen.
///
/// No AppBar: the whole screen is one [AnimatedContainer] painting a
/// vertical gradient from a muted color extracted from the current track's
/// artwork (top) down to a constant dark base (bottom), so the player feels
/// like it belongs to the album rather than sitting in a generic dark
/// scaffold. A top-left dismiss chevron closes the page; the system Back
/// button/gesture keeps working as it always has (it pops the route
/// regardless of whether the page has an AppBar).
///
/// Pushed from [MiniPlayer]'s tap (or anywhere else via [route]); the phone
/// track context sheet ([showTrackContextSheet]) is reused as-is for the
/// transport row's overflow button -- [library]/[store] are required for
/// that sheet to open, [artwork] is optional exactly like every other call
/// site.
class NowPlayingPage extends StatefulWidget {
  final PlayerService player;

  /// Artwork resolution chain (Plan 4). Null keeps the pre-Plan-4
  /// embedded-art-only behavior -- and also means no tint is ever
  /// extracted, so the page always shows [_kFallbackTint].
  final ArtworkResolver? artworkResolver;

  /// Needed to open the overflow ("more") sheet's "Add to playlist" list
  /// and the sheet itself. Null hides that affordance's functionality: the
  /// button still renders (the transport row is always five controls) but
  /// tapping it is a no-op, same discipline [showTrackContextSheet]'s own
  /// optional params use.
  final LibraryModel? library;
  final PlaylistStore? store;

  /// Enables the sheet's "Album artwork" entry, exactly like every other
  /// [showTrackContextSheet] call site.
  final ArtworkServices? artwork;

  const NowPlayingPage({
    super.key,
    required this.player,
    this.artworkResolver,
    this.library,
    this.store,
    this.artwork,
  });

  /// Route helper so callers (MiniPlayer, future deep links) push the page
  /// identically without importing MaterialPageRoute boilerplate.
  static Route<void> route({
    required PlayerService player,
    ArtworkResolver? artworkResolver,
    LibraryModel? library,
    PlaylistStore? store,
    ArtworkServices? artwork,
  }) => MaterialPageRoute<void>(
    builder: (_) => NowPlayingPage(
      player: player,
      artworkResolver: artworkResolver,
      library: library,
      store: store,
      artwork: artwork,
    ),
  );

  @override
  State<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends State<NowPlayingPage> {
  /// Resolved tints, keyed by [Track.contentId]. A present key with a null
  /// value means "resolved, and there is genuinely no tint" (no art / a
  /// near-grey cover) -- cached so the chain isn't re-run every time the
  /// listener revisits a track. Capped at [_kMaxTintCacheEntries], oldest
  /// (first inserted) evicted first.
  final Map<String, Color?> _tintCache = {};

  /// The tint currently painted. Left alone while a new track's tint is
  /// still resolving, so the gradient never flashes back to the fallback
  /// mid-resolution -- the previous track's tint simply stays up until the
  /// new one is ready.
  Color? _tint;

  /// Which track's tint [_tint] actually reflects.
  String? _tintedContentId;

  /// The track a resolution is currently in flight for, so a rebuild mid-
  /// resolution (the position ticks several times a second) doesn't fire a
  /// second, redundant resolve for the same track.
  String? _pendingContentId;

  @override
  void initState() {
    super.initState();
    final t = widget.player.current;
    if (t != null) _ensureTint(t);
  }

  /// Kicks off (or reuses) tint resolution for [t]. Idempotent per track:
  /// safe to call on every rebuild.
  void _ensureTint(Track t) {
    final id = t.contentId;
    if (_tintedContentId == id || _pendingContentId == id) return;
    _pendingContentId = id;
    if (_tintCache.containsKey(id)) {
      // Cache hit: still deferred (never setState synchronously from
      // within build) via a microtask rather than resolved inline.
      final cached = _tintCache[id];
      scheduleMicrotask(() => _applyTint(id, cached));
      return;
    }
    _resolveTint(t).then((color) => _applyTint(id, color));
  }

  Future<Color?> _resolveTint(Track t) async {
    final resolver = widget.artworkResolver;
    if (resolver == null) return null;
    try {
      final bytes = await resolver.resolve(ArtworkRequest.forTrack(t));
      if (bytes == null || bytes.isEmpty) return null;
      final u8 = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
      return await dominantMutedColor(u8);
    } catch (_) {
      return null;
    }
  }

  void _applyTint(String id, Color? color) {
    if (!_tintCache.containsKey(id)) {
      _tintCache[id] = color;
      while (_tintCache.length > _kMaxTintCacheEntries) {
        _tintCache.remove(_tintCache.keys.first);
      }
    }
    if (_pendingContentId == id) _pendingContentId = null;
    if (!mounted) return;
    // Stale: the track moved on while this resolution was in flight.
    if (widget.player.current?.contentId != id) return;
    setState(() {
      _tint = color;
      _tintedContentId = id;
    });
  }

  void _openMore(BuildContext context, Track t) {
    final library = widget.library;
    final store = widget.store;
    if (library == null || store == null) return;
    showTrackContextSheet(
      context,
      track: t,
      library: library,
      store: store,
      artwork: widget.artwork,
      player: widget.player,
    );
  }

  /// The folder the file actually lives in -- its immediate parent
  /// directory's name (for a flat root that IS the root, e.g. "loose
  /// tracks - old"; inside an album root it's the album folder). The
  /// reference design's third metadata line names the track's source.
  String _sourceFolder(Track t) {
    return p.basename(p.dirname(p.join(t.rootPath, t.relPath)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: widget.player,
        builder: (context, _) {
          final t = widget.player.current;
          if (t == null) {
            // Queue exhausted while the page is open: nothing to show.
            return const SizedBox.shrink();
          }
          _ensureTint(t);

          final total = widget.player.duration ?? Duration.zero;
          final pos = widget.player.position > total
              ? total
              : widget.player.position;
          const timeStyle = TextStyle(
            fontSize: 11,
            color: Colors.white70,
            fontFeatures: [FontFeature.tabularFigures()],
          );

          return AnimatedContainer(
            key: const Key('np-tint'),
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [_tint ?? _kFallbackTint, _kBaseTint],
              ),
            ),
            child: SafeArea(
              // Swipe DOWN anywhere = dismiss, same as the top-left chevron.
              // The content scroll view rejects vertical drags whenever the
              // content fits the screen (ClampingScrollPhysics'
              // shouldAcceptUserOffset -- the normal portrait case), so this
              // detector receives them; in the rare overflow case scrolling
              // wins and the chevron/Back still dismiss.
              child: GestureDetector(
                key: const Key('np-swipe-dismiss'),
                behavior: HitTestBehavior.opaque,
                onVerticalDragEnd: (details) {
                  if ((details.primaryVelocity ?? 0) > 600) {
                    Navigator.of(context).pop();
                  }
                },
                child: Column(
                  children: [
                    Expanded(
                      child: Stack(
                        children: [
                          LayoutBuilder(
                            builder: (context, constraints) {
                              // Per spec: large art is min(width - 56, 400).
                              final artSize = math
                                  .min(constraints.maxWidth - 56, 400.0)
                                  .toDouble();
                              // Scroll fallback: centered when everything fits (the
                              // normal portrait-phone case), scrollable instead of
                              // RenderFlex-overflowing when it doesn't (landscape /
                              // tiny windows).
                              return SingleChildScrollView(
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    minHeight: constraints.maxHeight,
                                  ),
                                  // Gives the Column a bounded height even inside
                                  // the scroll view, so its Spacers can flex; when
                                  // content genuinely exceeds the viewport they
                                  // collapse to zero and it scrolls.
                                  child: IntrinsicHeight(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 24,
                                        vertical: 16,
                                      ),
                                      child: Column(
                                        // Top-anchored, Apple-Music-style: art high,
                                        // the control block low, flexible breathing
                                        // room between (Spacers collapse to zero when
                                        // the scroll fallback kicks in -- fine).
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          // Room for the close chevron overlaid above.
                                          const SizedBox(height: 40),
                                          Center(
                                            child: Container(
                                              width: artSize,
                                              height: artSize,
                                              decoration: BoxDecoration(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: Colors.black
                                                        .withValues(
                                                          alpha: 0.35,
                                                        ),
                                                    blurRadius: 24,
                                                    offset: const Offset(0, 8),
                                                  ),
                                                ],
                                              ),
                                              child: ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                                child: AlbumArt(
                                                  contentId: t.contentId,
                                                  file: File(
                                                    p.join(
                                                      t.rootPath,
                                                      t.relPath,
                                                    ),
                                                  ),
                                                  size: artSize,
                                                  resolver:
                                                      widget.artworkResolver,
                                                  track: t,
                                                ),
                                              ),
                                            ),
                                          ),
                                          const Spacer(flex: 3),
                                          const SizedBox(height: 20),
                                          // Left-aligned metadata block with the two
                                          // circular actions on its right -- the
                                          // reference design's title row (its star and
                                          // dots become our shuffle and more).
                                          Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.center,
                                            children: [
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      t.title,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        fontSize: 21,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 4),
                                                    Text(
                                                      t.artist,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        fontSize: 15,
                                                        color: Colors.white70,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 2),
                                                    Text(
                                                      _sourceFolder(t),
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        fontSize: 12.5,
                                                        color: Colors.white54,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              IconButton(
                                                key: const Key('np-shuffle'),
                                                tooltip: 'Shuffle',
                                                onPressed:
                                                    widget.player.toggleShuffle,
                                                iconSize: 30,
                                                icon: MetroIcon(
                                                  widget.player.shuffle
                                                      ? kIconShuffleOnBare
                                                      : kIconShuffleOffBare,
                                                  size: 30,
                                                  color: widget.player.shuffle
                                                      ? AppColors.accent
                                                      : Colors.white,
                                                ),
                                              ),
                                              const SizedBox(width: 4),
                                              IconButton(
                                                key: const Key('np-more'),
                                                tooltip: 'More',
                                                onPressed: () =>
                                                    _openMore(context, t),
                                                icon: const Icon(
                                                  Icons.more_horiz,
                                                  color: Colors.white,
                                                  size: 34,
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 20),
                                          // Fat rounded fill, NO thumb dot (the
                                          // reference look). Dragging still seeks --
                                          // the gesture never needed a thumb.
                                          SliderTheme(
                                            data: SliderTheme.of(context).copyWith(
                                              activeTrackColor: Colors.white,
                                              inactiveTrackColor:
                                                  Colors.white24,
                                              trackHeight: 7,
                                              thumbShape:
                                                  SliderComponentShape.noThumb,
                                              overlayShape: SliderComponentShape
                                                  .noOverlay,
                                              trackShape:
                                                  const RoundedRectSliderTrackShape(),
                                            ),
                                            child: Slider(
                                              key: const Key('np-seek'),
                                              value: total.inMilliseconds == 0
                                                  ? 0
                                                  : (pos.inMilliseconds /
                                                            total
                                                                .inMilliseconds)
                                                        .clamp(0.0, 1.0),
                                              onChanged: (v) => widget.player.seek(
                                                Duration(
                                                  milliseconds:
                                                      (v * total.inMilliseconds)
                                                          .round(),
                                                ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                          // Times directly below the bar: current on
                                          // the left, total on the right.
                                          Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceBetween,
                                            children: [
                                              Text(
                                                _fmt(pos),
                                                maxLines: 1,
                                                softWrap: false,
                                                style: timeStyle,
                                              ),
                                              Text(
                                                _fmt(total),
                                                maxLines: 1,
                                                softWrap: false,
                                                style: timeStyle,
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 16),
                                          // Exactly three transport controls, large,
                                          // centered -- shuffle and more moved up to
                                          // the title row.
                                          Row(
                                            key: const Key('np-transport'),
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              IconButton(
                                                tooltip: 'Previous',
                                                iconSize: 44,
                                                icon: const MetroIcon(
                                                  kIconPreviousBare,
                                                  size: 44,
                                                  color: Colors.white,
                                                ),
                                                onPressed:
                                                    widget.player.previous,
                                              ),
                                              const SizedBox(width: 40),
                                              IconButton(
                                                tooltip: widget.player.playing
                                                    ? 'Pause'
                                                    : 'Play',
                                                iconSize: 48,
                                                icon: MetroIcon(
                                                  widget.player.playing
                                                      ? kIconPauseBare
                                                      : kIconPlayBare,
                                                  size: 48,
                                                  color: Colors.white,
                                                ),
                                                onPressed: widget
                                                    .player
                                                    .togglePlayPause,
                                              ),
                                              const SizedBox(width: 40),
                                              IconButton(
                                                tooltip: 'Next',
                                                iconSize: 44,
                                                icon: const MetroIcon(
                                                  kIconNextBare,
                                                  size: 44,
                                                  color: Colors.white,
                                                ),
                                                onPressed: widget.player.next,
                                              ),
                                            ],
                                          ),
                                          const Spacer(flex: 2),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                          Positioned(
                            top: 4,
                            left: 4,
                            child: IconButton(
                              key: const Key('np-close'),
                              tooltip: 'Close',
                              icon: const Icon(
                                Icons.keyboard_arrow_down,
                                color: Colors.white70,
                                size: 28,
                              ),
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                          ),
                        ],
                      ),
                    ),
                    _navBar(context),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// The persistent shortcut bar pinned under the player content -- evenly
  /// spaced white glyphs on the gradient's dark base, per the second
  /// reference screenshot. Each pops this page and asks the shell to show
  /// that view (see [phoneShellNavRequest]).
  Widget _navBar(BuildContext context) {
    const views = [
      PhoneView.library,
      PhoneView.queue,
      PhoneView.folders,
      PhoneView.artists,
      PhoneView.playlists,
    ];
    return SizedBox(
      height: 54,
      child: Row(
        key: const Key('np-nav-bar'),
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          for (final v in views)
            IconButton(
              key: Key('np-nav-${v.name}'),
              tooltip: v.label,
              icon: Icon(v.icon, color: Colors.white70, size: 26),
              onPressed: () {
                Navigator.of(context).pop();
                phoneShellNavRequest.value = v;
              },
            ),
        ],
      ),
    );
  }
}
