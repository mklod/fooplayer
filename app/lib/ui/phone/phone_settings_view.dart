// Last modified: 2026-08-05--0751
//
// Phone-shell Settings view (Plan 2b): the drawer's Settings destination.
// Per the plan spec it "reuses existing SettingsDialog content as a page":
// the shared [LibraryRootsEditor] (the exact widget the desktop dialog
// wraps) rendered as the shell body, live against the same sources the
// desktop dialog listens to -- [LibraryRootsPrefs] for the configured
// roots and [LibraryModel] for the per-root manifest health notes. The
// "Sync" entry (Plan 3 Task 11) is the phone-shell equivalent of
// SettingsDialog's "Sync…" button: same [SyncUiSeams], same Android-only
// gate, pushed as a page instead of nested in another dialog.
//
// BUG FIX (silent "Set up" no-op, reported on first phone install): every
// outcome of tapping "Set up" for a manifest-less root used to look like
// nothing happened -- a denied permission bailed silently, a successful
// seed never refreshed rootsMissingManifest so the row/button just sat
// there until a restart or the 5-minute tick, and a seed failure was
// equally quiet. [onSetUpRootAction] (built once in main.dart via
// `makeSetUpRootAction`, see model/set_up_root.dart) narrates all three
// outcomes as a SnackBar instead.
import 'package:flutter/material.dart';

import 'storage_access.dart';

import '../../model/library_model.dart';
import '../../model/library_roots_prefs.dart';
import '../../model/set_up_root.dart';
import '../adaptive.dart';
import '../app_theme.dart';
import '../settings_dialog.dart';
import '../sync_view.dart';

/// The phone Settings page body. PhoneShell supplies the chrome (AppBar
/// titled "Settings"); this widget is just the content, mounted via
/// `viewBuilders[PhoneView.settings]` in main.dart.
///
/// Add/remove write through [LibraryRootsPrefs] exactly like the desktop
/// dialog -- main.dart's listener on the prefs then persists config.json
/// and reloads the library, so the phone gets the same
/// change-roots-and-the-feed-follows behavior with zero new plumbing.
class PhoneSettingsView extends StatelessWidget {
  final LibraryModel library;
  final LibraryRootsPrefs libraryRootsPrefs;

  /// Folder picker; the production default is the native OS directory
  /// dialog (same as desktop). Injectable so widget tests can supply a
  /// fake (native platform dialogs can't run under `flutter test`).
  final Future<String?> Function() pickDirectory;

  /// LAN-sync seams (Plan 3 Task 11) -- null hides the "Sync" entry
  /// entirely, same as [settings_dialog.SettingsDialog.syncUi].
  final SyncUiSeams? syncUi;

  /// The Set-up action (permission request -> seed -> reload), built once
  /// in main.dart by `makeSetUpRootAction`. Null keeps the affordance
  /// hidden entirely (`onSetUpRoot: null` below) rather than falling back
  /// to the old silent inline closure -- production always supplies a real
  /// one; only fixtures that don't care about Set-up leave this null.
  final SetUpRootAction? onSetUpRootAction;

  const PhoneSettingsView({
    super.key,
    required this.library,
    required this.libraryRootsPrefs,
    this.pickDirectory = defaultPickDirectory,
    this.syncUi,
    this.onSetUpRootAction,
  });

  Future<void> _setUpRoot(BuildContext context, String root) async {
    final action = onSetUpRootAction;
    if (action == null) return; // no wiring; onSetUpRoot is null below
    final result = await action(root);
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    switch (result) {
      case SetUpRootDenied():
        messenger.showSnackBar(
          SnackBar(
            content: const Text(
              'fooplayer needs "All files access" to read music folders',
            ),
            action: SnackBarAction(
              label: 'Open settings',
              onPressed: () => openStorageSettings(),
            ),
          ),
        );
      case SetUpRootFailed(status: final status):
        messenger.showSnackBar(
          SnackBar(content: Text('Could not set up — $status')),
        );
      case SetUpRootDone(tracks: final tracks):
        messenger.showSnackBar(
          SnackBar(content: Text('Set up complete — $tracks tracks found')),
        );
    }
  }

  void _openSync(BuildContext context) {
    final seams = syncUi;
    if (seams == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Sync')),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            // Re-read at open time -- see SettingsDialog._openSync's doc.
            child: SyncView(
              settings: seams.currentSettings(),
              onSave: seams.onSave,
              runSync: seams.runSync,
              probe: seams.probe,
              discoverRoots: seams.discoverRoots,
              cancelSync: seams.cancelSync,
              activity: seams.activity,
              pickDirectory: pickDirectory,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // Same pair the desktop dialog's ListenableBuilder merges: prefs for
      // the roots list, library for rootsMissingManifest/rootsFailed.
      listenable: Listenable.merge([libraryRootsPrefs, library]),
      builder: (context, _) => SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Library roots',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.ink,
              ),
            ),
            const SizedBox(height: 8),
            LibraryRootsEditor(
              roots: libraryRootsPrefs.roots,
              rootsMissingManifest: library.rootsMissingManifest,
              rootsFailed: library.rootsFailed,
              pickDirectory: pickDirectory,
              onAddRoot: libraryRootsPrefs.addRoot,
              onRemoveRoot: libraryRootsPrefs.removeRoot,
              // Android has no foolib to seed a folder with, so setting one
              // up has to be something the app itself can do. Null hides
              // the button entirely rather than falling back to a silent
              // no-op -- see [onSetUpRootAction]'s doc.
              onSetUpRoot: onSetUpRootAction == null
                  ? null
                  : (root) => _setUpRoot(context, root),
            ),
            const SizedBox(height: 24),
            Text(
              'Appearance',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.ink,
              ),
            ),
            const SizedBox(height: 8),
            const ThemePreferencePicker(),
            if (isAndroidPlatform() && syncUi != null) ...[
              const SizedBox(height: 24),
              Text(
                'LAN sync',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.ink,
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                key: const Key('phone-sync-entry'),
                dense: true,
                title: const Text('Sync'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openSync(context),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
