// Which layout this device gets: the desktop panel layout or the phone shell.
//
// Last modified: 2026-07-29--1625
import 'dart:io';
import 'package:flutter/widgets.dart';

/// Test seam for the Android check: when non-null it replaces
/// `Platform.isAndroid` entirely, so widget tests running on a desktop host
/// can pump the phone shell (`isAndroidOverride = true`) or pin the
/// desktop-stays-HomeScreen behavior (`isAndroidOverride = false`) without
/// any real platform-channel mocking. Tests MUST reset it to null in
/// `tearDown` -- it's process-global by design (the switch is consulted from
/// main.dart's widget tree, far from any injectable constructor).
@visibleForTesting
bool? isAndroidOverride;

/// Test seam for [hasFileExplorer].
@visibleForTesting
bool? isWindowsOverride;

/// The shortest side, in logical pixels, at or above which a device is a
/// tablet rather than a phone.
///
/// Deliberately the SHORTEST side rather than the current width, so the
/// answer cannot change when the device is rotated -- rotating a tablet must
/// not change which application it appears to be. Keying off width did
/// exactly that: a Galaxy Tab S9+ is 1318x824 logical pixels (1752x2800
/// physical at density 340), so any width threshold between 825 and 1318
/// gives it the panel layout in landscape and the compact one in portrait.
/// That was measured on the device, not assumed.
///
/// 700 sits in a wide empty gap: the largest phones are around 480 on their
/// shortest side, and a 10-inch tablet is 800 or more. Nothing real is near
/// it, which is what a breakpoint wants.
const double kTabletShortestSide = 700;

/// Whether this device should render the desktop panel layout (`HomeScreen`)
/// rather than the phone shell (`PhoneShell`).
///
/// A desktop OS always does, however narrow the window is dragged -- the
/// panel layout is what that machine is for, and resizing a window is not a
/// change of device.
///
/// Everywhere else it is a question about the device rather than the
/// platform, because a widescreen tablet is as capable a player as a desktop
/// and a 2800px screen showing one track per row wastes it. A tablet gets the
/// panels in both orientations and a phone gets the compact view in both; see
/// [kTabletShortestSide] for why that is the right shape.
bool useDesktopLayout(BuildContext context) {
  final isAndroid = isAndroidOverride ?? Platform.isAndroid;
  if (!isAndroid &&
      (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
    return true;
  }
  return MediaQuery.sizeOf(context).shortestSide >= kTabletShortestSide;
}

/// Whether this app instance should render the phone UI (`PhoneShell`)
/// instead of the desktop panel layout.
bool usePhoneShell(BuildContext context) => !useDesktopLayout(context);

/// Whether "View in folder" can do anything here.
///
/// It shells out to `explorer.exe`, so it is a Windows action specifically,
/// not a desktop-layout one. Now that the panel layout also runs on a tablet,
/// the item would otherwise sit in the menu doing nothing.
bool get hasFileExplorer => isWindowsOverride ?? Platform.isWindows;
