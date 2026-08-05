// Last modified: 2026-08-05--0751
import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/material.dart';

import 'adaptive.dart';
import 'app_theme.dart';
import 'sync_view.dart';

/// Production folder picker: file_selector's native OS directory dialog.
/// Injected as [SettingsDialog.pickDirectory]'s default so tests can supply
/// a fake instead (native platform dialogs can't run under `flutter test`).
Future<String?> defaultPickDirectory() => file_selector.getDirectoryPath();

/// The library-roots list with add/remove controls -- the CONTENT the
/// desktop [SettingsDialog] wraps in an [AlertDialog] and the phone
/// Settings page (`ui/phone/phone_settings_view.dart`) embeds directly,
/// per the Plan 2b spec ("Settings reuses existing SettingsDialog content
/// as a page"). One implementation, two chromes.
///
/// Fully controlled by its caller: [roots], [rootsMissingManifest] and
/// [rootsFailed] are rendered as given, and [onAddRoot]/[onRemoveRoot] are
/// called to request a change -- this widget holds no state of its own, so
/// re-opening it (or rebuilding it inside a `ListenableBuilder` over the
/// roots source of truth, as `home_screen.dart` does) always reflects the
/// current configuration exactly, with a single place (main.dart's wiring)
/// owning persistence and triggering a library reload.
class LibraryRootsEditor extends StatelessWidget {
  final List<String> roots;
  final List<String> rootsMissingManifest;
  final List<String> rootsFailed;
  final Future<String?> Function() pickDirectory;
  final ValueChanged<String> onAddRoot;
  final ValueChanged<String> onRemoveRoot;

  /// Scans a folder that has no manifest and writes one, so a freshly added
  /// music folder actually shows its contents. Null hides the affordance and
  /// leaves the old "seed with foolib" wording -- which is fine on a desktop
  /// with the CLI to hand and useless anywhere else.
  final Future<void> Function(String root)? onSetUpRoot;

  const LibraryRootsEditor({
    super.key,
    required this.roots,
    this.rootsMissingManifest = const [],
    this.rootsFailed = const [],
    this.pickDirectory = defaultPickDirectory,
    required this.onAddRoot,
    required this.onRemoveRoot,
    this.onSetUpRoot,
  });

  Future<void> _addFolder() async {
    final path = await pickDirectory();
    if (path == null || path.isEmpty) return;
    onAddRoot(path);
  }

  @override
  Widget build(BuildContext context) {
    final missing = rootsMissingManifest.toSet();
    final failed = rootsFailed.toSet();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (roots.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('No library roots configured.'),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final root in roots)
                  ListTile(
                    key: Key('root-tile-$root'),
                    dense: true,
                    title: Text(
                      root,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: missing.contains(root)
                        ? Text(
                            onSetUpRoot == null
                                ? 'no library manifest — seed with foolib'
                                : 'not set up yet — tap Set up to scan it',
                          )
                        : failed.contains(root)
                        ? const Text(
                            'library manifest is corrupt — reseed with foolib to repair',
                          )
                        : null,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (onSetUpRoot != null &&
                            (missing.contains(root) || failed.contains(root)))
                          TextButton(
                            key: Key('setup-root-$root'),
                            onPressed: () => onSetUpRoot!(root),
                            child: const Text('Set up'),
                          ),
                        IconButton(
                          key: Key('remove-root-$root'),
                          icon: const Icon(Icons.remove_circle_outline),
                          tooltip: 'Remove',
                          onPressed: () => onRemoveRoot(root),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('add-folder-button'),
            onPressed: _addFolder,
            icon: const Icon(Icons.add),
            label: const Text('Add folder…'),
          ),
        ),
      ],
    );
  }
}

/// The desktop settings dialog: [LibraryRootsEditor] in an [AlertDialog]
/// (opened from the sidebar's gear button -- see `home_screen.dart`). The
/// phone shell shows the same editor as a drawer-navigated page instead.
class SettingsDialog extends StatelessWidget {
  final List<String> roots;
  final List<String> rootsMissingManifest;
  final List<String> rootsFailed;
  final Future<String?> Function() pickDirectory;
  final ValueChanged<String> onAddRoot;
  final ValueChanged<String> onRemoveRoot;

  final Future<void> Function(String root)? onSetUpRoot;

  /// LAN-sync seams (Plan 3 Task 11) -- null on any platform/test that
  /// doesn't wire sync, which hides the "Sync…" action entirely regardless
  /// of [isAndroidPlatform]. Real wiring (main.dart) always supplies this on
  /// Android; there is no SMB bridge implementation anywhere else, which is
  /// what [isAndroidPlatform] actually gates.
  final SyncUiSeams? syncUi;

  const SettingsDialog({
    super.key,
    required this.roots,
    this.rootsMissingManifest = const [],
    this.rootsFailed = const [],
    this.pickDirectory = defaultPickDirectory,
    required this.onAddRoot,
    required this.onRemoveRoot,
    this.onSetUpRoot,
    this.syncUi,
  });

  void _openSync(BuildContext context) {
    final seams = syncUi;
    if (seams == null) return;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sync'),
        content: SizedBox(
          width: 480,
          // SyncView's content (three fields, the connection check, the
          // roots list, Sync now) is taller than an AlertDialog's default
          // content area on a short window -- scroll it rather than
          // overflow, same as the report dialogs already do.
          child: SingleChildScrollView(
            child: SyncView(
              // Re-read at open time, not captured once at app startup, so
              // a second visit in the same session sees whatever the first
              // visit's edits already saved.
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
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Library roots'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LibraryRootsEditor(
              roots: roots,
              rootsMissingManifest: rootsMissingManifest,
              rootsFailed: rootsFailed,
              pickDirectory: pickDirectory,
              onAddRoot: onAddRoot,
              onRemoveRoot: onRemoveRoot,
              // BUG FIX: this dialog used to build LibraryRootsEditor
              // without forwarding its own onSetUpRoot at all, so a tablet
              // (which runs this same panel-layout dialog, not the phone
              // Settings page -- see adaptive.dart's useDesktopLayout)
              // never saw the "Set up" affordance for a freshly-added,
              // not-yet-scanned root, however many callers passed one in.
              onSetUpRoot: onSetUpRoot,
            ),
            const SizedBox(height: 16),
            Text(
              'APPEARANCE',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 6),
            const ThemePreferencePicker(),
          ],
        ),
      ),
      actions: [
        // Android only -- there is no SMB bridge implementation on desktop.
        // [syncUi] being null (any platform/test that hasn't wired sync)
        // hides this regardless of the platform check.
        if (isAndroidPlatform() && syncUi != null)
          TextButton(
            key: const Key('open-sync-view'),
            onPressed: () => _openSync(context),
            child: const Text('Sync…'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
