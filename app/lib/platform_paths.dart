import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The Windows-only default library root, used as-is on Windows and as the
/// (unreachable-in-practice) fallback default elsewhere. Kept here, not
/// inlined in [defaultLibraryRoots], purely so the literal has one home.
const _windowsDefaultLibraryRoot = r'L:\music (original structure)';

/// Returns the app's persistent data directory (config, metadata cache),
/// creating nothing itself -- callers create it on first write, exactly as
/// the pre-Android code did.
///
/// - Windows: `%APPDATA%\fooplayer` -- byte-identical to the app's original
///   (Windows-only) behavior, so existing users' `config.json` and
///   `meta_cache.json` are found at the same path they always have been.
/// - Other platforms (Android): the app's private application-support
///   directory via [path_provider], since there's no `%APPDATA%` equivalent
///   and the app must stay within its sandbox.
Future<Directory> appDataDir() async {
  if (Platform.isWindows) {
    return Directory(p.join(Platform.environment['APPDATA']!, 'fooplayer'));
  }
  return getApplicationSupportDirectory();
}

/// Returns the library root(s) a first-run config should default to.
///
/// - Windows: the original hardcoded network-share path -- unchanged.
/// - Other platforms (Android): a single app-private `music/` directory
///   under [appDataDir], created here if it doesn't already exist. Android
///   has no shared network drive to point at, and per the Android
///   test-build scope this app requests no storage permissions, so the
///   (small, seeded) test library lives inside the app's own sandbox.
Future<List<String>> defaultLibraryRoots() async {
  if (Platform.isWindows) {
    return [_windowsDefaultLibraryRoot];
  }
  final dir = Directory(p.join((await appDataDir()).path, 'music'));
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  return [dir.path];
}
