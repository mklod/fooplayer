// The persistent "here is what I am doing" bar.
//
// Sits above the now-playing bar and stays for the whole duration of whatever
// is running -- the opposite of the three-second toast it replaces, which
// announced a twenty-minute job and then said nothing.
//
// Last modified: 2026-07-28--1730

import 'package:flutter/material.dart';

import '../model/activity_model.dart';
import '../model/library_model.dart';
import '../player/player_service.dart';
import 'app_theme.dart';

/// The window's persistent footer: what is running on the left, how many
/// tracks are in view on the right.
///
/// Always present, even idle -- the track count is a permanent readout, and a
/// strip that appears and disappears under the now-playing bar would jump the
/// layout every time a background job started.
class ActivityBar extends StatelessWidget {
  final ActivityModel activity;
  final LibraryModel library;

  /// Consulted so the footer can carry the transport when the now-playing
  /// strip is collapsed. Null in widget tests that build the bar alone.
  final PlayerService? player;

  /// Whether that strip is currently hidden.
  final bool nowPlayingHidden;

  /// Brings the strip back. Collapsing it used to be a one-way door: there
  /// was no way back to the controls short of restarting the app.
  final VoidCallback? onExpand;

  const ActivityBar({
    super.key,
    required this.activity,
    required this.library,
    this.player,
    this.nowPlayingHidden = false,
    this.onExpand,
  });

  /// `m:ss`, matching the seek bar's own formatting.
  static String _clock(Duration d) {
    final total = d.inSeconds;
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([activity, library, ?player]),
      builder: (context, _) {
        final jobs = activity.active;
        final bar = Container(
          key: const Key('activity-bar'),
          decoration: const BoxDecoration(
            color: AppColors.panelBg,
            border: Border(top: BorderSide(color: AppColors.hairline)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                // Background work wins the left-hand side while it lasts --
                // it is transient and worth interrupting for. The rest of the
                // time, that space carries what is playing.
                child: jobs.isNotEmpty
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [for (final job in jobs) _row(job)],
                      )
                    : _nowPlayingLine() ?? const SizedBox(height: 18),
              ),
              const SizedBox(width: 16),
              Text(
                '${_thousands(_footerTrackCount())} tracks',
                key: const Key('footer-track-count'),
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.inkSecondary,
                ),
              ),
            ],
          ),
        );

        // The whole strip is the way back to the player. No button: the bar
        // is one line of text and a target that small would be worse than
        // clicking anywhere along it.
        if (!nowPlayingHidden || onExpand == null) return bar;
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            key: const Key('footer-expand'),
            behavior: HitTestBehavior.opaque,
            onTap: onExpand,
            child: bar,
          ),
        );
      },
    );
  }

  /// While the Queue is showing, the footer counts the queue itself --
  /// [LibraryModel.visibleTracks] is untouched browsing state that the Queue
  /// destination doesn't repurpose (see [LibraryModel.showQueue]'s doc), so
  /// it still holds whatever the library view last showed. Reported live:
  /// "I'm in a queue of two songs, and the bottom status bar says 2,548
  /// tracks."
  int _footerTrackCount() {
    final p = player;
    if (library.showingQueue && p != null) return p.queueController.queue.length;
    return library.visibleTracks.length;
  }

  /// "Title — Artist    1:04 / 4:27", in the footer's own type.
  ///
  /// Deliberately text and not a progress bar: this is the collapsed state,
  /// and a bar here would just be a smaller version of the thing that was
  /// collapsed. Numbers say the same in one line.
  Widget? _nowPlayingLine() {
    final p = player;
    if (p == null || !nowPlayingHidden) return null;
    final track = p.current;
    if (track == null) return null;

    final total = p.duration;
    final pos = (total != null && p.position > total) ? total : p.position;
    final label = track.artist.isEmpty
        ? track.title
        : '${track.title} — ${track.artist}';

    return Row(
      key: const Key('footer-now-playing'),
      children: [
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.inkSecondary,
            ),
          ),
        ),
        const SizedBox(width: 18),
        Text(
          total == null
              ? _clock(pos)
              : '${_clock(pos)} / ${_clock(total)}',
          style: const TextStyle(
            fontSize: 12,
            color: AppColors.inkSecondary,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  Widget _row(BackgroundActivity job) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        const SizedBox(
          width: 13,
          height: 13,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            job.text,
            key: Key('activity-${job.id}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: AppColors.ink),
          ),
        ),
        if (job.hasProgress) ...[
          const SizedBox(width: 12),
          SizedBox(
            width: 160,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: job.fraction,
                minHeight: 4,
                backgroundColor: AppColors.hairline,
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

String _thousands(int n) {
  final s = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}
