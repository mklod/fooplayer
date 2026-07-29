// Sending the app to the background instead of killing it.
//
// Back at the root of a phone app normally finishes the activity. Here that
// is the wrong thing twice over: the library takes minutes to read over the
// network, so coming back is a cold start, and playback state -- what is
// queued, where you were in the list -- goes with it. Backgrounding leaves
// all of it standing, and the foreground service keeps the music playing.
//
// Last modified: 2026-07-29--0020

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The channel MainActivity answers on.
const MethodChannel appChannel = MethodChannel('dev.mklod.fooplayer/app');

/// Moves the task to the background, the way the system Back gesture does
/// for a launcher-rooted task.
///
/// Returns false when the platform has no such notion (anything but
/// Android) or the call fails, so a caller can fall back to whatever it
/// would otherwise have done.
Future<bool> moveAppToBackground() async {
  if (defaultTargetPlatform != TargetPlatform.android) return false;
  try {
    return await appChannel.invokeMethod<bool>('moveToBackground') ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}
