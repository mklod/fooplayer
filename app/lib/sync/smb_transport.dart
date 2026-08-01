// Last modified: 2026-07-31--2123
//
// SmbTransport: Android-only SyncTransport over the Kotlin SmbBridge
// (SMBJ). Every method here crosses a MethodChannel to a background
// executor on the platform side -- see SmbBridge.kt's class doc for the
// threading and error-mapping contract this class assumes.
//
// CRITICAL SEMANTIC (pinned by SyncEngine's per-root exception containment,
// carried forward from Task 9's review -- see sync_transport.dart's
// SyncTransport doc for the full interface contract): every method here
// THROWS on a connection drop or any other transport-level error -- never a
// silent partial listing, an empty list standing in for "dir unreachable",
// or a null standing in for "read failed". `null` from readFile means
// EXACTLY "object does not exist" (the platform side maps that from
// NT_STATUS_OBJECT_NAME_NOT_FOUND / OBJECT_PATH_NOT_FOUND); every other
// failure is a PlatformException that propagates as-is -- this class adds
// no try/catch of its own around it. The ONE deliberate exception is
// [probe], which swallows everything (including a MissingPluginException on
// a non-Android platform) and resolves to false, so callers can cheaply ask
// "is the NAS there" without a try/catch of their own.
//
// STALE-HANDLE RECOVERY (review round 1, Critical C-1): SmbBridge.kt is now
// a process singleton, so a fresh Kotlin bridge instance should never again
// orphan a cached Dart handle -- but this class still treats a "no SMB
// session" platform error as recoverable rather than fatal, as a second
// line of defense: it drops the stale [_handle], reconnects once, and
// retries the call once. Any OTHER error still propagates untouched.
//
// SHARED PROGRESS STATE (review round 1, Important I-3): the native
// EventChannel supports exactly ONE active listener -- a second
// SmbTransport instance calling receiveBroadcastStream() would silently
// steal the first instance's subscription. taskIds, the stream
// subscription, and the callback registry are therefore all
// static/process-global (matching the Kotlin bridge being a singleton
// too), ref-counted per instance so the LAST instance's [close] is the one
// that actually tears the subscription down.
//
// CANCEL (whole-branch review, Finding I-1): unlike the progress state
// above, in-flight taskIds are tracked PER INSTANCE, not process-global --
// [cancelInFlight] only needs to reach downloads THIS instance started.
// SmbBridge.kt's `cancelled` set is keyed on taskId alone and checked only
// between chunks (see its class doc), so cancelling a taskId that has
// already finished (or never existed) is a harmless, self-cleaning no-op
// on the platform side -- which is exactly why every per-call
// PlatformException from the 'cancel' method is swallowed here rather than
// surfaced: a cancel racing the download's own completion is the normal
// case, not an error.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:fooplayer_core/fooplayer_core.dart' as core;

import 'sync_transport.dart';

const MethodChannel _channel = MethodChannel('dev.mklod.fooplayer/smb');
const EventChannel _progressChannel = EventChannel('dev.mklod.fooplayer/smb-progress');

/// [SyncTransport] over SMB, via the Kotlin SmbBridge platform channel.
/// Android-only -- there is no platform implementation anywhere else, so on
/// any other platform every method surfaces a [MissingPluginException] from
/// the channel itself, same as any other unimplemented platform channel
/// (probe is the one method that turns that into a plain `false` instead).
///
/// Connects lazily: constructing an instance talks to nothing, so a caller
/// can build one and call [probe] cheaply before deciding whether to do any
/// real work. The underlying platform `connect` call happens on first use
/// of any other method, and its handle is reused for the lifetime of this
/// instance (or until [close]) -- transparently reconnected once if the
/// platform ever reports it stale (see the class doc above).
class SmbTransport implements SyncTransport {
  final String host;
  final String share;
  final String basePath;

  int? _handle;
  Future<int>? _connecting;
  bool _holdsProgressRef = false;

  /// TaskIds for downloads THIS instance currently has in flight -- fuels
  /// [cancelInFlight]. Per-instance, unlike the progress state below (see
  /// the CANCEL note in this file's header doc for why).
  final Set<String> _inFlightTaskIds = {};

  SmbTransport({required this.host, required this.share, required this.basePath});

  // ---- process-global progress state (shared across ALL instances) ----
  static int _nextTaskId = 0;
  static int _progressRefCount = 0;
  static StreamSubscription<dynamic>? _progressSub;
  static final Map<String, void Function(int got, int total)> _progressCallbacks = {};

  static void _retainProgressSubscription() {
    _progressRefCount++;
    if (_progressSub != null) return;
    _progressSub = _progressChannel.receiveBroadcastStream().listen((event) {
      final map = Map<Object?, Object?>.from(event as Map);
      final taskId = map['taskId'] as String;
      final callback = _progressCallbacks[taskId];
      if (callback == null) return; // a different (or already-cleaned-up) task
      callback((map['got'] as num).toInt(), (map['total'] as num).toInt());
    });
  }

  /// Only the ref count reaching zero actually cancels the shared
  /// subscription -- another still-open [SmbTransport] instance may be
  /// mid-download and relying on it.
  static void _releaseProgressSubscription() {
    if (_progressRefCount == 0) return;
    _progressRefCount--;
    if (_progressRefCount == 0) {
      _progressSub?.cancel();
      _progressSub = null;
    }
  }

  Map<String, Object?> get _connectArgs => {
    'host': host,
    'share': share,
    'basePath': basePath,
  };

  Future<int> _ensureConnected() {
    final existing = _handle;
    if (existing != null) return Future.value(existing);
    return _connecting ??= _connect();
  }

  Future<int> _connect() async {
    try {
      final handle = await _channel.invokeMethod<int>('connect', _connectArgs);
      if (handle == null) {
        throw PlatformException(code: 'smb', message: 'connect returned no handle');
      }
      _handle = handle;
      return handle;
    } finally {
      // Cleared on both success (now cached in _handle, this future's job
      // is done) and failure (so the NEXT call retries instead of replaying
      // a cached failed future forever).
      _connecting = null;
    }
  }

  static bool _isMissingSession(Object error) =>
      error is PlatformException && (error.message ?? '').contains('no SMB session');

  /// Runs [body] with a connected handle. If the platform reports the
  /// handle no longer exists (SmbBridge.kt's `sessionFor` throwing "no SMB
  /// session for handle N") -- which the Kotlin-side process-singleton fix
  /// should make unreachable in practice, but this is the belt-and-
  /// suspenders half of that same fix -- drops the stale [_handle],
  /// reconnects exactly once, and retries [body] exactly once with the
  /// fresh handle. Any other failure (including a SECOND missing-session
  /// error on the retry) propagates as-is; this is a single recovery
  /// attempt, not a retry loop.
  Future<T> _withSession<T>(Future<T> Function(int handle) body) async {
    final handle = await _ensureConnected();
    try {
      return await body(handle);
    } catch (e) {
      if (!_isMissingSession(e)) rethrow;
      _handle = null;
      final freshHandle = await _ensureConnected();
      return body(freshHandle);
    }
  }

  @override
  Future<bool> probe() async {
    try {
      final result = await _channel.invokeMethod<bool>('probe', _connectArgs);
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<core.RemoteFile>> listTree(String relDir) {
    return _withSession((handle) async {
      final result = await _channel.invokeMethod<List<Object?>>('listTree', {
        'handle': handle,
        'relDir': relDir,
      });
      return [for (final entry in result ?? const []) _remoteFileFromMap(entry)];
    });
  }

  core.RemoteFile _remoteFileFromMap(Object? entry) {
    final map = Map<Object?, Object?>.from(entry as Map);
    return core.RemoteFile(
      relPath: map['relPath'] as String,
      size: (map['size'] as num).toInt(),
      mtimeMs: (map['mtimeMs'] as num).toInt(),
    );
  }

  @override
  Future<List<int>?> readFile(String relPath) {
    return _withSession(
      (handle) => _channel.invokeMethod<Uint8List>('readFile', {
        'handle': handle,
        'relPath': relPath,
      }),
    );
  }

  @override
  Future<void> writeFile(String relPath, List<int> bytes) {
    return _withSession(
      (handle) => _channel.invokeMethod<void>('writeFile', {
        'handle': handle,
        'relPath': relPath,
        'bytes': Uint8List.fromList(bytes),
      }),
    );
  }

  @override
  Future<void> downloadToFile(
    String relPath,
    File local, {
    void Function(int got, int total)? onProgress,
  }) async {
    // Parent-dir creation is dart:io work done here rather than left to the
    // Kotlin side, matching every other SyncTransport implementation's
    // "creates parent dirs" contract regardless of what the platform side
    // does with the local path.
    await local.parent.create(recursive: true);

    await _withSession((handle) async {
      final taskId = (_nextTaskId++).toString();
      // Added before the platform call is even sent (not after it
      // succeeds) -- cancelInFlight must be able to reach a download that's
      // still connecting/starting on the platform side, not just one
      // already mid-transfer.
      _inFlightTaskIds.add(taskId);
      if (onProgress != null) {
        _ensureProgressSubscription();
        _progressCallbacks[taskId] = onProgress;
      }
      try {
        await _channel.invokeMethod<bool>('downloadToFile', {
          'handle': handle,
          'relPath': relPath,
          'localPath': local.path,
          'taskId': taskId,
        });
      } finally {
        // Removed here UNCONDITIONALLY (success or failure) rather than
        // relying solely on a got>=total self-removal in the listener --
        // guards against a leaked entry if the final progress event is
        // ever lost for any reason (SmbBridge.kt now always sends
        // (total, total) unconditionally for the final call, but this
        // class shouldn't have to trust that as the ONLY cleanup path).
        // Safe to remove even before the corresponding event has been
        // processed: SmbBridge.kt posts the final progress event and this
        // call's own result through the SAME Handler(mainLooper) in that
        // order, so on a real device the event is always fully delivered
        // before this future resolves.
        _progressCallbacks.remove(taskId);
        _inFlightTaskIds.remove(taskId);
      }
    });
  }

  /// Cancels every download THIS instance currently has in flight, by
  /// sending the platform 'cancel' method for each in-flight taskId. Fires
  /// them all rather than stopping at the first: this is a whole-sync
  /// cancel (SyncEngine.cancel), not a single-download cancel, and every
  /// in-flight taskId here is a candidate. Each call's own PlatformException
  /// is swallowed -- see the CANCEL note in this file's header doc for why
  /// that's the correct behavior, not a hidden failure.
  Future<void> cancelInFlight() async {
    final taskIds = List<String>.of(_inFlightTaskIds);
    await Future.wait([for (final taskId in taskIds) _sendCancel(taskId)]);
  }

  Future<void> _sendCancel(String taskId) async {
    try {
      await _channel.invokeMethod<void>('cancel', {'taskId': taskId});
    } on PlatformException {
      // Racing the download's own completion is the normal case -- see
      // cancelInFlight's doc.
    }
  }

  void _ensureProgressSubscription() {
    if (_holdsProgressRef) return;
    _holdsProgressRef = true;
    _retainProgressSubscription();
  }

  @override
  Future<void> deleteRemote(String relPath) {
    return _withSession(
      (handle) => _channel.invokeMethod<void>('deleteRemote', {
        'handle': handle,
        'relPath': relPath,
      }),
    );
  }

  @override
  Future<void> close() async {
    if (_holdsProgressRef) {
      _holdsProgressRef = false;
      _releaseProgressSubscription();
    }
    // NOT clearing _progressCallbacks here: it's shared across every
    // SmbTransport instance in the process, so wiping it on THIS
    // instance's close() would drop another still-open instance's
    // in-flight callbacks. Entries this instance registered are already
    // self-cleaning (see downloadToFile's finally above).

    final handle = _handle;
    _handle = null;
    if (handle != null) {
      await _channel.invokeMethod<void>('close', {'handle': handle});
    }
  }

  /// [android.os.StatFs] on the nearest existing ancestor of [localPath] --
  /// independent of any connected handle, since it's asked about a LOCAL
  /// path (typically to check space before a sync starts). Throws (rather
  /// than returning a misleadingly-conservative 0) if the platform call
  /// itself fails, consistent with every other method on this class.
  static Future<int> freeSpace(String localPath) async {
    final result = await _channel.invokeMethod<int>('freeSpace', {'localPath': localPath});
    if (result == null) {
      throw PlatformException(code: 'smb', message: 'freeSpace returned no value');
    }
    return result;
  }
}
