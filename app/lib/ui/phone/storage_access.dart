// Getting permission to read the folder the user picked.
//
// On the tablet this looked like a library bug: a Music folder with 474
// tracks and a .library.json sitting in it, added as a root, and an empty
// library. The app could LIST the folder and could not open a single file in
// it -- it held no storage permission at all.
//
// Why all-files access and not just READ_MEDIA_AUDIO: fooplayer keeps its
// library manifest and artwork sidecar beside the music, as .library.json and
// .artwork.json. Those are not media files, so the media-scoped permissions
// cannot read them however many audio files they unlock. Same reason Kodi and
// VLC ask for it.
//
// Android only; every call is a no-op elsewhere, so callers do not have to
// branch on platform.
//
// Last modified: 2026-07-29--0400

import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

/// Whether the app can currently read arbitrary files in shared storage.
Future<bool> hasFullStorageAccess() async {
  if (!Platform.isAndroid) return true;
  if (await Permission.manageExternalStorage.isGranted) return true;
  // Pre-13 devices, where plain storage access is the whole story.
  return Permission.storage.isGranted;
}

/// Asks for it.
///
/// All-files access cannot be granted from an in-app dialog: Android sends
/// the user to a system settings screen and returns nothing, so the result
/// here is only ever "did they have it by the time they came back". The
/// caller re-checks rather than trusting a return value.
Future<bool> requestFullStorageAccess() async {
  if (!Platform.isAndroid) return true;

  // The media-scoped ones first: they are a normal in-app prompt, and on a
  // device where the user declines all-files access they at least let the
  // audio play even though the sidecars stay unreadable.
  await Permission.audio.request();

  if (await Permission.manageExternalStorage.isGranted) return true;
  final result = await Permission.manageExternalStorage.request();
  if (result.isGranted) return true;

  // Older devices have no such screen; the plain permission is the answer.
  final legacy = await Permission.storage.request();
  return legacy.isGranted;
}

/// Opens the system settings page for the app, for the case where the user
/// denied permanently and the request no longer prompts.
Future<void> openStorageSettings() => openAppSettings();
