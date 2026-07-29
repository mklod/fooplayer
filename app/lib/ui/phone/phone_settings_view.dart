// Last modified: 2026-07-24--1855
//
// Phone-shell Settings view (Plan 2b): the drawer's Settings destination.
// Per the plan spec it "reuses existing SettingsDialog content as a page":
// the shared [LibraryRootsEditor] (the exact widget the desktop dialog
// wraps) rendered as the shell body, live against the same sources the
// desktop dialog listens to -- [LibraryRootsPrefs] for the configured
// roots and [LibraryModel] for the per-root manifest health notes.
import 'dart:io';

import 'package:flutter/material.dart';

import 'storage_access.dart';

import '../../model/library_model.dart';
import '../../model/library_roots_prefs.dart';
import '../app_theme.dart';
import '../settings_dialog.dart';

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

  const PhoneSettingsView({
    super.key,
    required this.library,
    required this.libraryRootsPrefs,
    this.pickDirectory = defaultPickDirectory,
  });

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
            const Text(
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
              // up has to be something the app itself can do.
              onSetUpRoot: (root) async {
                if (!await requestFullStorageAccess()) return;
                await library.seedRoot(Directory(root));
              },
            ),
          ],
        ),
      ),
    );
  }
}
