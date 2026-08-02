// The Settings "Set up" button, for a manifest-less root, gives no feedback
// in any outcome:
//   1. permission denied / user backs out of the All-files screen -> the
//      inline `if (!await requestFullStorageAccess()) return;` bails
//      SILENTLY.
//   2. seed SUCCEEDS -> .library.json written, but nothing refreshes:
//      LibraryModel.rootsMissingManifest only updates inside load(), so the
//      row still says "not set up yet" and the button stays until an app
//      restart or the 5-minute tick.
//   3. seedRoot returns null (busy / scan error) -> also silent.
//
// This is the widget-free, testable core of the fix: a pure action builder
// that narrates every outcome as a [SetUpRootResult] the UI can turn into a
// SnackBar, and reloads the library on the success path -- awaited before
// the result is handed back, so a caller that reacts to [SetUpRootDone]
// never races the reload's own listeners.
//
// Last modified: 2026-08-01--1946

/// Outcome of a Set-up attempt, for the UI to narrate.
sealed class SetUpRootResult {}

/// The user did not have (or did not grant) All-files access. Neither
/// [SetUpRootAction]'s `seed` nor `reloadLibrary` ran.
class SetUpRootDenied extends SetUpRootResult {}

/// `seed` returned null (busy elsewhere, or the scan/manifest write itself
/// failed). `reloadLibrary` did NOT run -- there is nothing new to reload.
class SetUpRootFailed extends SetUpRootResult {
  /// `libraryStatus()` read right after the failed seed, e.g.
  /// "could not read Music: timed out".
  final String status;
  SetUpRootFailed(this.status);
}

/// `seed` succeeded and the library has been reloaded.
class SetUpRootDone extends SetUpRootResult {
  /// How many tracks the seed scan found.
  final int tracks;
  SetUpRootDone(this.tracks);
}

/// A ready-to-call Set-up action for one root path.
typedef SetUpRootAction = Future<SetUpRootResult> Function(String rootPath);

/// Builds the Set-up action from its four seams:
///  - [requestAccess]: asks for All-files access; returns whether the app
///    has it by the time the call returns (production: `requestFullStorageAccess`).
///  - [seed]: scans the root and writes its manifest, returning the track
///    count or null on failure (production: `library.seedRoot`).
///  - [reloadLibrary]: refreshes the live feed / rootsMissingManifest so the
///    UI reflects the just-written manifest without waiting for a restart
///    or the periodic tick (production: `reloadLibrary`).
///  - [libraryStatus]: reads the library's current status line, used to
///    narrate a seed failure (production: `() => library.status`).
///
/// Behavior: `requestAccess() == false` -> [SetUpRootDenied], `seed`/`reload`
/// NOT called. `seed(rootPath) == null` -> [SetUpRootFailed] carrying
/// `libraryStatus()`, `reload` NOT called. `seed(rootPath) == n` -> awaits
/// `reloadLibrary()`, THEN returns [SetUpRootDone](n).
SetUpRootAction makeSetUpRootAction({
  required Future<bool> Function() requestAccess,
  required Future<int?> Function(String rootPath) seed,
  required Future<void> Function() reloadLibrary,
  required String Function() libraryStatus,
}) {
  return (String rootPath) async {
    if (!await requestAccess()) return SetUpRootDenied();

    final tracks = await seed(rootPath);
    if (tracks == null) return SetUpRootFailed(libraryStatus());

    await reloadLibrary();
    return SetUpRootDone(tracks);
  };
}
