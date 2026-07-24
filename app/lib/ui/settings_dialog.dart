import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/material.dart';

/// Production folder picker: file_selector's native OS directory dialog.
/// Injected as [SettingsDialog.pickDirectory]'s default so tests can supply
/// a fake instead (native platform dialogs can't run under `flutter test`).
Future<String?> defaultPickDirectory() => file_selector.getDirectoryPath();

/// Lists the app's configured library roots with add/remove controls.
///
/// Fully controlled by its caller: [roots] and [rootsMissingManifest] are
/// rendered as given, and [onAddRoot]/[onRemoveRoot] are called to request
/// a change -- this widget holds no state of its own, so re-opening it (or
/// rebuilding it inside a `ListenableBuilder` over the roots source of
/// truth, as `home_screen.dart` does) always reflects the current
/// configuration exactly, with a single place (main.dart's wiring) owning
/// persistence and triggering a library reload.
class SettingsDialog extends StatelessWidget {
  final List<String> roots;
  final List<String> rootsMissingManifest;
  final Future<String?> Function() pickDirectory;
  final ValueChanged<String> onAddRoot;
  final ValueChanged<String> onRemoveRoot;

  const SettingsDialog({
    super.key,
    required this.roots,
    this.rootsMissingManifest = const [],
    this.pickDirectory = defaultPickDirectory,
    required this.onAddRoot,
    required this.onRemoveRoot,
  });

  Future<void> _addFolder() async {
    final path = await pickDirectory();
    if (path == null || path.isEmpty) return;
    onAddRoot(path);
  }

  @override
  Widget build(BuildContext context) {
    final missing = rootsMissingManifest.toSet();
    return AlertDialog(
      title: const Text('Library roots'),
      content: SizedBox(
        width: 480,
        child: Column(
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
                        title: Text(root, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: missing.contains(root)
                            ? const Text('no library manifest — seed with foolib')
                            : null,
                        trailing: IconButton(
                          key: Key('remove-root-$root'),
                          icon: const Icon(Icons.remove_circle_outline),
                          tooltip: 'Remove',
                          onPressed: () => onRemoveRoot(root),
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
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
