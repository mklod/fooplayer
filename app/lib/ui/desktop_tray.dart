// Windows system-tray presence, so the desktop app can stay running as the
// library's indexer without occupying the taskbar.
//
// The problem it solves: `.library.json` is only refreshed while fooplayer
// runs, so music dropped onto the NAS from anywhere (the voice-to-code
// download flow, most often) stayed invisible to the phone until someone
// opened the desktop app -- which is exactly what you cannot do when you
// are away from home. This machine is already up 24/7 (verified: 12+ day
// uptime, sleep disabled in the active power scheme), so the cheapest
// reliable fix is simply to keep fooplayer running on it, out of the way.
//
// Deliberately NOT a second indexer: nothing here scans or writes a
// manifest. It only keeps the process alive and gives it a visible handle.
// One writer of `.library.json` is a property worth protecting -- see
// docs/superpowers/specs for the sync design's date_added invariants.
//
// Last modified: 2026-09-10--1611

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// True on the desktop platforms that have a tray to sit in.
bool get traySupported =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

/// Whether this process was launched to sit in the tray from the start --
/// i.e. by the Windows Startup-folder shortcut, which passes `--tray`.
/// A hand-launched fooplayer shows its window as usual.
bool startsHidden(List<String> args) => args.contains('--tray');

/// Keeps fooplayer alive in the notification area.
///
/// Closing the window HIDES it rather than exiting, because an accidental
/// click on the X would otherwise silently stop library indexing -- the
/// one failure mode this whole feature exists to prevent. "Quit fooplayer"
/// in the tray menu is the deliberate way out.
class DesktopTray with TrayListener, WindowListener {
  /// Rescan-now action for the tray menu; also what the tooltip's
  /// last-scan time reflects. Injected so this class stays free of model
  /// dependencies.
  final Future<void> Function() onScanNow;

  /// Called for a real quit, so main() can flush prefs before exit.
  final Future<void> Function() onQuit;

  DesktopTray({required this.onScanNow, required this.onQuit});

  /// The tray icon, as an ABSOLUTE path.
  ///
  /// tray_manager hands the string straight to Win32 `LoadImage(...,
  /// LR_LOADFROMFILE)`, which resolves a relative path against the
  /// process working directory -- not the source tree and not the bundle.
  /// The first version passed `windows/runner/resources/app_icon.ico`,
  /// which never resolved at runtime, so LoadImage returned NULL and the
  /// tray showed nothing at all. Build the path off [Platform
  /// .resolvedExecutable] instead, where Flutter puts bundled assets.
  ///
  /// It is a purpose-built multi-size .ico (16/20/24/32/40/48/64/256)
  /// rendered from the app's own pink-note artwork -- LoadImage asks for
  /// `SM_CXSMICON` (16px), and the app icon alone starts at 48px, which
  /// would only ever be downscaled.
  static String get _iconPath => p.join(
    p.dirname(Platform.resolvedExecutable),
    'data',
    'flutter_assets',
    'assets',
    'icons',
    'tray_icon.ico',
  );

  DateTime? _lastScan;

  /// Installs the tray icon and takes over the window's close button.
  /// [startHidden] leaves the window down at launch (the boot case).
  Future<void> start({required bool startHidden}) async {
    await windowManager.ensureInitialized();
    // Intercept the X so it hides instead of terminating the indexer.
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);

    trayManager.addListener(this);
    try {
      await trayManager.setIcon(_iconPath);
    } catch (e) {
      // A missing icon must never stop the app from running -- but it must
      // not fail SILENTLY either. Swallowing this is exactly why the first
      // version shipped with an invisible tray icon and no clue why.
      debugPrint('fooplayer: tray icon failed to load from $_iconPath ($e)');
    }
    await _refreshTooltip();
    await _buildMenu();

    if (startHidden) {
      await windowManager.hide();
    }
  }

  Future<void> _buildMenu() async {
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: 'Show fooplayer'),
          MenuItem(key: 'scan', label: 'Scan library now'),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: 'Quit fooplayer'),
        ],
      ),
    );
  }

  /// The tooltip doubles as the health indicator: if indexing has silently
  /// stopped, hovering the icon is the fastest way to notice.
  Future<void> _refreshTooltip() async {
    final scan = _lastScan;
    final when = scan == null
        ? 'no scan yet'
        : 'last scan ${scan.hour.toString().padLeft(2, '0')}:'
              '${scan.minute.toString().padLeft(2, '0')}';
    try {
      await trayManager.setToolTip('fooplayer — $when');
    } catch (_) {
      // Tooltip is a nicety.
    }
  }

  /// Call after every successful scan so the tooltip stays truthful.
  Future<void> noteScanCompleted(DateTime at) async {
    _lastScan = at;
    await _refreshTooltip();
  }

  @override
  void onTrayIconMouseDown() => unawaited(_show());

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(_show());
      case 'scan':
        unawaited(onScanNow());
      case 'quit':
        unawaited(_quit());
    }
  }

  /// The window close button: hide, never exit. See the class doc.
  @override
  void onWindowClose() => unawaited(windowManager.hide());

  Future<void> _show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _quit() async {
    await onQuit();
    await dispose();
    // setPreventClose(true) is still in force, so destroy() is what
    // actually ends the process.
    await windowManager.destroy();
  }

  Future<void> dispose() async {
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    try {
      await trayManager.destroy();
    } catch (_) {
      // Already gone.
    }
  }
}