// Last modified: 2026-08-05--0751
//
// Persisted config for LAN sync: where the NAS is (host/share/basePath) and
// which top-level root folders under that base the user has opted into
// syncing. Lives at config.json's `"sync"` key, read/written the same way
// `LayoutPrefs` owns `"ui"` -- this class only knows how to parse/serialize
// itself; the actual file I/O belongs to whoever reads config.json (Task 11).
library;

/// Default NAS location -- matches the real one this app was built for
/// (see CLAUDE.md's Kodi/NAS notes). A user with a different NAS still gets
/// a sensible starting point to edit rather than empty fields.
const kSyncDefaultHost = 'murkyserver';
const kSyncDefaultShare = 'drop';
const kSyncDefaultBasePath = 'music (original structure)';

/// Where synced NAS folders land when [SyncSettings.localFolder] is unset.
const kSyncDefaultLocalFolder = '/storage/emulated/0/Music';

class SyncSettings {
  String host;
  String share;
  String basePath;

  /// The LOCAL folder every synced NAS root is placed INSIDE (NAS `albums`
  /// -> `<localFolder>/albums`). Empty = never chosen, callers fall back to
  /// [kSyncDefaultLocalFolder]. This exists because the target used to be
  /// silently DERIVED (common parent of the configured library roots) --
  /// which, with a single root at /storage/emulated/0/Music, resolved to
  /// the internal-storage ROOT and scattered album folders there (reported
  /// live). The target is now explicit, visible, and user-picked.
  String localFolder;

  /// NAS root folder name -> whether the user has checked it for sync.
  Map<String, bool> roots;

  SyncSettings({
    this.host = kSyncDefaultHost,
    this.share = kSyncDefaultShare,
    this.basePath = kSyncDefaultBasePath,
    this.localFolder = '',
    Map<String, bool>? roots,
  }) : roots = roots ?? <String, bool>{};

  /// The folder syncs actually use: [localFolder], or the default when the
  /// user has never picked one.
  String get effectiveLocalFolder =>
      localFolder.isEmpty ? kSyncDefaultLocalFolder : localFolder;

  /// Parses the `"sync"` subtree of config.json. Returns `null` when the key
  /// is absent or isn't a map -- i.e. sync has never been configured, which
  /// callers (the settings UI, the sync scheduler) treat differently from
  /// "configured with nothing checked yet". Missing/invalid individual
  /// fields inside an existing `"sync"` map fall back to their defaults
  /// rather than making the whole block unparseable, same tolerance as
  /// [core.Manifest] and every other on-disk shape in this app.
  static SyncSettings? fromConfig(Map<String, dynamic> raw) {
    final sync = raw['sync'];
    if (sync is! Map<String, dynamic>) return null;

    final host = sync['host'];
    final share = sync['share'];
    final basePath = sync['basePath'];
    final localFolder = sync['localFolder'];
    final rawRoots = sync['roots'];

    final roots = <String, bool>{};
    if (rawRoots is Map) {
      rawRoots.forEach((key, value) {
        if (key is String && value is bool) roots[key] = value;
      });
    }

    return SyncSettings(
      host: host is String && host.isNotEmpty ? host : kSyncDefaultHost,
      share: share is String && share.isNotEmpty ? share : kSyncDefaultShare,
      basePath: basePath is String && basePath.isNotEmpty
          ? basePath
          : kSyncDefaultBasePath,
      localFolder: localFolder is String ? localFolder : '',
      roots: roots,
    );
  }

  Map<String, dynamic> toJson() => {
    'host': host,
    'share': share,
    'basePath': basePath,
    'localFolder': localFolder,
    'roots': roots,
  };

  /// Whether there is anything for the sync engine to actually do -- an
  /// empty/all-unchecked [roots] map means the user has opened the settings
  /// dialog but not opted any folder in yet.
  bool get anyChecked => roots.values.any((checked) => checked);
}
