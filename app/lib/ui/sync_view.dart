// Sync settings + "Sync now" + the report it ends in (Plan 3 Task 11).
//
// Pure content, no chrome of its own -- same split as `LibraryRootsEditor`
// (settings_dialog.dart): the desktop/tablet path wraps this in an
// `AlertDialog` (SettingsDialog's "Sync…" button), the phone path pushes it
// as a page (phone_settings_view.dart's "Sync" tile). Every side effect --
// reading/writing config.json, talking to the NAS -- lives behind the five
// injected seams below; this widget never touches `dart:io` or a
// `SyncTransport` directly, which is what makes it testable with fakes.
//
// Last modified: 2026-08-05--1055
import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'friendly_paths.dart';
import 'report_dialog.dart';
import '../model/activity_model.dart';
import '../sync/sync_engine.dart';
import '../sync/sync_settings.dart';

/// Bundles the five [SyncView] seams so callers that only need to THREAD
/// them through several widget layers -- `SettingsDialog` via
/// `HomeScreen`/`_Sidebar` on a tablet, `PhoneSettingsView` on a phone --
/// pass one object instead of five separate optional parameters at every
/// hop. [SyncView] itself still takes the five named parameters directly
/// (that's the shape its widget tests construct it with); this bundle
/// exists purely so the pass-through call sites don't each grow five more
/// fields of their own.
///
/// [currentSettings] is a getter, not a plain value, so that reopening the
/// sync UI later in the same app session -- after an earlier visit already
/// called [onSave] -- sees the latest edit rather than whatever was current
/// when main.dart built this bundle once at startup.
class SyncUiSeams {
  final SyncSettings Function() currentSettings;
  final void Function(SyncSettings) onSave;
  final Future<SyncReport> Function() runSync;
  final Future<bool> Function() probe;
  final Future<List<String>> Function() discoverRoots;

  /// Cancels the in-flight [runSync] call (whole-branch review, Finding
  /// I-1) -- main.dart wires this to the currently-running SyncEngine's
  /// `cancel()`. A no-op if nothing is running (SyncView only ever surfaces
  /// its Cancel button while `_syncing` is true, so in practice this is
  /// only ever called mid-run), so callers don't need to guard the call
  /// themselves.
  final Future<void> Function() cancelSync;

  /// The app's [ActivityModel], so the sync page can show the SAME live
  /// progress line the phone strip and the notification already carry
  /// ("Syncing albums — 68.0 MB — 14 / 126") right next to the button the
  /// user pressed -- reported live: a sync started from this page showed
  /// only the button's spinner, with the real numbers hidden on other
  /// screens. Optional so widget tests (and any caller without a model)
  /// can omit it; null just means no progress line, never an error.
  final ActivityModel? activity;

  const SyncUiSeams({
    required this.currentSettings,
    required this.onSave,
    required this.runSync,
    required this.probe,
    required this.discoverRoots,
    required this.cancelSync,
    this.activity,
  });
}

/// LAN-sync settings: NAS location fields, a connection check, discovered
/// root checkboxes, and the "Sync now" action that ends in [SyncReportDialog].
class SyncView extends StatefulWidget {
  final SyncSettings settings;
  final void Function(SyncSettings) onSave;
  final Future<SyncReport> Function() runSync;
  final Future<bool> Function() probe;
  final Future<List<String>> Function() discoverRoots;

  /// See [SyncUiSeams.cancelSync]'s doc.
  final Future<void> Function() cancelSync;

  /// See [SyncUiSeams.activity]'s doc.
  final ActivityModel? activity;

  /// Native directory picker for the "Sync to" folder. Null hides the
  /// Change... button (bare test fixtures); both production settings
  /// surfaces pass their own picker through.
  final Future<String?> Function()? pickDirectory;

  const SyncView({
    super.key,
    required this.settings,
    required this.onSave,
    required this.runSync,
    required this.probe,
    required this.discoverRoots,
    required this.cancelSync,
    this.activity,
    this.pickDirectory,
  });

  @override
  State<SyncView> createState() => _SyncViewState();
}

class _SyncViewState extends State<SyncView> {
  // Owned clone -- [widget.settings] is only ever a prefill snapshot from
  // the caller; every edit from here on lives in this copy and is pushed
  // out via [widget.onSave], never mutated back into the widget's own prop.
  late final SyncSettings _settings;

  late final TextEditingController _hostController;
  late final TextEditingController _shareController;
  late final TextEditingController _baseController;
  late final FocusNode _hostFocus;
  late final FocusNode _shareFocus;
  late final FocusNode _baseFocus;

  bool _probing = false;
  bool? _probeOk; // null = never checked this session

  bool _discovering = true;
  List<String> _discoveredRoots = const [];

  bool _syncing = false;

  // Non-null exception text from the last failed [_runSync] -- cleared at
  // the START of every new attempt (not just on success), so a second Sync
  // now click always gives the error a chance to go away rather than
  // leaving a stale message next to a dialog that just opened.
  String? _syncError;

  @override
  void initState() {
    super.initState();
    _settings = SyncSettings(
      host: widget.settings.host,
      share: widget.settings.share,
      basePath: widget.settings.basePath,
      localFolder: widget.settings.localFolder,
      roots: Map<String, bool>.of(widget.settings.roots),
    );
    _hostController = TextEditingController(text: _settings.host);
    _shareController = TextEditingController(text: _settings.share);
    _baseController = TextEditingController(text: _settings.basePath);
    _hostFocus = FocusNode()
      ..addListener(
        () => _onFocusChange(_hostFocus, _commitHost, _hostController),
      );
    _shareFocus = FocusNode()
      ..addListener(
        () => _onFocusChange(_shareFocus, _commitShare, _shareController),
      );
    _baseFocus = FocusNode()
      ..addListener(
        () => _onFocusChange(_baseFocus, _commitBase, _baseController),
      );
    _loadRoots();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _shareController.dispose();
    _baseController.dispose();
    _hostFocus.dispose();
    _shareFocus.dispose();
    _baseFocus.dispose();
    super.dispose();
  }

  // Tapping straight from one field into another (or into "Check
  // connection") never fires onSubmitted -- only losing focus does, via
  // this listener. onSubmitted itself still calls the same commit function,
  // redundantly but harmlessly (both are idempotent against the already-
  // current value).
  void _onFocusChange(
    FocusNode node,
    void Function(String) commit,
    TextEditingController controller,
  ) {
    if (!node.hasFocus) commit(controller.text);
  }

  void _save() => widget.onSave(_settings);

  void _commitHost(String v) {
    if (_settings.host == v) return;
    setState(() => _settings.host = v);
    _save();
  }

  void _commitShare(String v) {
    if (_settings.share == v) return;
    setState(() => _settings.share = v);
    _save();
  }

  void _commitBase(String v) {
    if (_settings.basePath == v) return;
    setState(() => _settings.basePath = v);
    _save();
  }

  Future<void> _loadRoots() async {
    List<String> roots;
    try {
      roots = await widget.discoverRoots();
    } catch (_) {
      // No connection yet, or the NAS is down -- an empty list reads the
      // same as "nothing discovered", which is honest enough without a
      // dedicated error seam.
      roots = const [];
    }
    if (!mounted) return;
    setState(() {
      _discoveredRoots = roots;
      _discovering = false;
    });
  }

  Future<void> _checkConnection() async {
    setState(() {
      _probing = true;
      _probeOk = null;
    });
    bool ok;
    try {
      ok = await widget.probe();
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _probing = false;
      _probeOk = ok;
    });
  }

  Future<void> _changeLocalFolder() async {
    final pick = widget.pickDirectory;
    if (pick == null) return;
    final String? path;
    try {
      path = await pick();
    } catch (_) {
      return; // dismissed/failed native dialog -- keep the current target
    }
    if (path == null || path.isEmpty || !mounted) return;
    final chosen = path;
    setState(() => _settings.localFolder = chosen);
    _save();
  }

  void _toggleRoot(String name, bool? checked) {
    setState(() => _settings.roots[name] = checked ?? false);
    _save();
  }

  Future<void> _runSync() async {
    setState(() {
      _syncing = true;
      _syncError = null;
    });
    // No runZonedGuarded/FlutterError.onError exists above this widget, so
    // an uncaught exception from widget.runSync() would otherwise become an
    // invisible unhandled-Future error on-device: the button would simply
    // re-enable with no dialog and no message, indistinguishable from
    // "nothing happened" even when files genuinely copied before the
    // failure. Catching it here and surfacing [_syncError] is the only
    // thing standing between a real failure and total silence.
    SyncReport? report;
    try {
      report = await widget.runSync();
    } catch (e) {
      if (mounted) setState(() => _syncError = e.toString());
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
    if (report == null) return; // failed -- _syncError above says why
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => SyncReportDialog(report: report!),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('sync-host'),
          controller: _hostController,
          focusNode: _hostFocus,
          decoration: const InputDecoration(labelText: 'NAS host'),
          onSubmitted: _commitHost,
        ),
        const SizedBox(height: 8),
        TextField(
          key: const Key('sync-share'),
          controller: _shareController,
          focusNode: _shareFocus,
          decoration: const InputDecoration(labelText: 'Share'),
          onSubmitted: _commitShare,
        ),
        const SizedBox(height: 8),
        TextField(
          key: const Key('sync-base'),
          controller: _baseController,
          focusNode: _baseFocus,
          decoration: const InputDecoration(labelText: 'Base path'),
          onSubmitted: _commitBase,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            OutlinedButton(
              key: const Key('sync-check-connection'),
              onPressed: _probing ? null : _checkConnection,
              child: const Text('Check connection'),
            ),
            const SizedBox(width: 12),
            if (_probing)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (_probeOk != null)
              Expanded(
                child: Text(
                  _probeOk!
                      ? 'Connected to \\\\${_settings.host}\\${_settings.share}'
                      : 'Could not reach \\\\${_settings.host}\\${_settings.share}',
                  key: const Key('sync-probe-result'),
                  style: TextStyle(
                    fontSize: 12,
                    color: _probeOk!
                        ? AppColors.inkSecondary
                        : const Color(0xFFD70015),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 20),
        Text(
          'Sync to',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.inkSecondary,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                friendlyAndroidPath(_settings.effectiveLocalFolder),
                key: const Key('sync-local-folder'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: AppColors.ink),
              ),
            ),
            if (widget.pickDirectory != null)
              TextButton(
                key: const Key('sync-local-folder-change'),
                onPressed: _changeLocalFolder,
                child: const Text('Change…'),
              ),
          ],
        ),
        Text(
          'Each NAS folder below is placed inside this folder — '
          '"albums" becomes '
          '${friendlyAndroidPath(_settings.effectiveLocalFolder)} › albums.',
          style: TextStyle(fontSize: 11.5, color: AppColors.inkSecondary),
        ),
        const SizedBox(height: 20),
        Text(
          'NAS folders to sync',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.inkSecondary,
          ),
        ),
        const SizedBox(height: 4),
        if (_discovering)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else if (_discoveredRoots.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('No syncable folders found on the NAS.'),
          )
        else
          for (final name in _discoveredRoots)
            CheckboxListTile(
              key: Key('sync-root-$name'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(name),
              value: _settings.roots[name] ?? false,
              onChanged: (v) => _toggleRoot(name, v),
            ),
        const SizedBox(height: 16),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton(
              key: const Key('sync-now'),
              onPressed: _syncing ? null : _runSync,
              child: _syncing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Sync now'),
            ),
            // Only while a run is actually in flight -- cancelling an idle
            // engine is meaningless, and widget.cancelSync's own doc leans
            // on this widget being the thing that keeps that call a no-op
            // in practice. Tapping it does NOT flip any local state here:
            // the run completes normally through the engine (the current
            // root aborts as 'cancelled', already-checked roots still run),
            // and _runSync's own finally clause is what re-enables Sync now
            // and opens the report dialog -- no special cancelled-UI path.
            if (_syncing) ...[
              const SizedBox(width: 12),
              TextButton(
                key: const Key('sync-cancel'),
                onPressed: widget.cancelSync,
                child: const Text('Cancel'),
              ),
            ],
          ],
        ),
        // The engine's own live progress, rendered where the user is
        // actually looking during a page-initiated sync. Gated on _syncing
        // (not just the job's presence) so the app-start playlist reconcile
        // or a periodic tick doesn't paint a surprise line under an idle
        // button.
        if (_syncing && widget.activity != null)
          ListenableBuilder(
            listenable: widget.activity!,
            builder: (context, _) {
              BackgroundActivity? job;
              for (final j in widget.activity!.active) {
                if (j.id == ActivityIds.sync) job = j;
              }
              if (job == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      job.text,
                      key: const Key('sync-progress-line'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: AppColors.ink),
                    ),
                    if (job.hasProgress) ...[
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          key: const Key('sync-progress-bar'),
                          value: job.fraction,
                          minHeight: 4,
                          backgroundColor: AppColors.hairline,
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        if (_syncError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Sync failed: $_syncError',
              key: const Key('sync-error-line'),
              style: const TextStyle(fontSize: 12, color: Color(0xFFD70015)),
            ),
          ),
      ],
    );
  }
}

/// What a [SyncEngine.run] call actually did, in a window that waits to be
/// read -- same "embed-pass discipline" as [EmbedReportDialog]: a sync can
/// run for minutes over SMB, so its outcome gets a dialog that stays until
/// dismissed, not a SnackBar that's gone before anyone reads it. Built on
/// the shared [ReportDialog] shell every other long-running pass in this app
/// uses.
class SyncReportDialog extends StatelessWidget {
  final SyncReport report;

  const SyncReportDialog({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    // Biggest-first: the root that did the most work is the answer to "what
    // did this sync actually do?", so it leads. A cancelled run's
    // [SyncReport.roots] can be shorter than the checked-roots set -- this
    // renders exactly what's there, never zipped against expectation.
    final roots = List<RootSyncResult>.of(report.roots)
      ..sort((a, b) => _weight(b).compareTo(_weight(a)));

    return ReportDialog(
      reportKey: 'sync-report-dialog',
      title: 'Sync finished',
      children: [
        if (report.playlistNotes.isNotEmpty) ...[
          const Text(
            'Playlists',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          for (final note in report.playlistNotes) ReportNote(note),
          const SizedBox(height: 16),
        ],
        if (roots.isEmpty)
          const ReportNote('No roots were synced.')
        else
          for (final r in roots) _rootSection(r),
      ],
    );
  }

  static int _weight(RootSyncResult r) =>
      r.copied + r.updated + r.renamed + r.deleted + r.adopted;

  Widget _rootSection(RootSyncResult r) {
    // The sentinel used when the NAS never answered at all -- no real root
    // was ever attempted, so there is no per-root tally to show, only why.
    if (r.rootName.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          'Sync did not run: ${r.abortReason ?? "unknown reason"}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      );
    }

    // "files", never "tracks" -- sidecar files (artwork, playlists) are
    // folded into these same counts, so "tracks" would undercount what
    // actually moved. copiedBytes deliberately excludes recopy bytes (a
    // recopy is still content that changed, just not NEW content), so only
    // the copied clause ever gets a size figure.
    final bytesSuffix = r.copiedBytes > 0
        ? ' (${_humanBytes(r.copiedBytes)} new data)'
        : '';
    final line =
        '${r.rootName} — ${r.copied} files copied$bytesSuffix, '
        '${r.updated} files updated, ${r.renamed} files renamed, '
        '${r.deleted} files deleted, ${r.adopted} files adopted (already present)';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(line, style: const TextStyle(fontSize: 13)),
          if (r.aborted)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'Stopped: ${r.abortReason ?? "unknown reason"}',
                style: const TextStyle(fontSize: 12, color: Color(0xFFD70015)),
              ),
            ),
          for (final f in r.failures)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 8),
              child: Text(
                '${f.relPath}: ${f.reason}',
                style: TextStyle(fontSize: 12, color: AppColors.inkSecondary),
              ),
            ),
        ],
      ),
    );
  }

  static String _humanBytes(int bytes) {
    const kb = 1024;
    const mb = kb * 1024;
    const gb = mb * 1024;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(1)} KB';
    return '$bytes B';
  }
}
