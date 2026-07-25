// Last modified: 2026-07-24--1837
import 'dart:io';
import 'package:flutter/widgets.dart';

/// Test seam for [usePhoneShell]'s Android check: when non-null it replaces
/// `Platform.isAndroid` entirely, so widget tests running on a desktop host
/// can pump the phone shell (`isAndroidOverride = true`) or pin the
/// desktop-stays-HomeScreen behavior (`isAndroidOverride = false`) without
/// any real platform-channel mocking. Tests MUST reset it to null in
/// `tearDown` -- it's process-global by design (the switch is consulted from
/// main.dart's widget tree, far from any injectable constructor).
@visibleForTesting
bool? isAndroidOverride;

/// Whether this app instance should render the phone UI ([PhoneShell])
/// instead of the desktop panel layout (HomeScreen).
///
/// Per the Plan 2b spec: `Platform.isAndroid || shortestSide < 600` (the
/// size clause is tablet/future-mobile-target proofing) -- with one hard
/// guard in front: a desktop OS (Windows/macOS/Linux) NEVER satisfies it,
/// no matter how narrow its window is dragged. Desktop keeps its panel
/// layout byte-identical; the phone shell is a form-factor decision, not a
/// responsive-breakpoint one.
bool usePhoneShell(BuildContext context) {
  final isAndroid = isAndroidOverride ?? Platform.isAndroid;
  if (isAndroid) return true;
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    return false;
  }
  return MediaQuery.sizeOf(context).shortestSide < 600;
}
