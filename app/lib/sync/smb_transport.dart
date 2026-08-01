// Last modified: 2026-07-31--1912
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
/// instance (or until [close]).
class SmbTransport implements SyncTransport {
  final String host;
  final String share;
  final String basePath;

  int? _handle;
  Future<int>? _connecting;

  StreamSubscription<dynamic>? _progressSub;
  final Map<String, void Function(int got, int total)> _progressCallbacks = {};
  int _nextTaskId = 0;

  SmbTransport({required this.host, required this.share, required this.basePath});

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
  Future<List<core.RemoteFile>> listTree(String relDir) async {
    final handle = await _ensureConnected();
    final result = await _channel.invokeMethod<List<Object?>>('listTree', {
      'handle': handle,
      'relDir': relDir,
    });
    return [for (final entry in result ?? const []) _remoteFileFromMap(entry)];
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
  Future<List<int>?> readFile(String relPath) async {
    final handle = await _ensureConnected();
    return _channel.invokeMethod<Uint8List>('readFile', {
      'handle': handle,
      'relPath': relPath,
    });
  }

  @override
  Future<void> writeFile(String relPath, List<int> bytes) async {
    final handle = await _ensureConnected();
    await _channel.invokeMethod<void>('writeFile', {
      'handle': handle,
      'relPath': relPath,
      'bytes': Uint8List.fromList(bytes),
    });
  }

  @override
  Future<void> downloadToFile(
    String relPath,
    File local, {
    void Function(int got, int total)? onProgress,
  }) async {
    final handle = await _ensureConnected();
    // Parent-dir creation is dart:io work done here rather than left to the
    // Kotlin side, matching every other SyncTransport implementation's
    // "creates parent dirs" contract regardless of what the platform side
    // does with the local path.
    await local.parent.create(recursive: true);

    final taskId = (_nextTaskId++).toString();
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
      // Deliberately NOT removed here on success: the platform side sends
      // the final (got == total) progress event as a SEPARATE message from
      // this call's own result, and nothing guarantees it has already been
      // delivered to the listener below by the moment this future resolves
      // (progress travels over the EventChannel, the result over this
      // MethodChannel -- two independent message hops). Removing eagerly
      // here raced that event and silently dropped it. The listener cleans
      // up its own entry once it actually sees got >= total.
    } catch (e) {
      // On failure/cancellation the platform side never reaches its final
      // postProgress call, so nothing will ever self-clean this entry --
      // remove it here instead, or it leaks for the life of this instance.
      _progressCallbacks.remove(taskId);
      rethrow;
    }
  }

  void _ensureProgressSubscription() {
    if (_progressSub != null) return;
    _progressSub = _progressChannel.receiveBroadcastStream().listen((event) {
      final map = Map<Object?, Object?>.from(event as Map);
      final taskId = map['taskId'] as String;
      final callback = _progressCallbacks[taskId];
      if (callback == null) return; // a different (or already-cleaned-up) task
      final got = (map['got'] as num).toInt();
      final total = (map['total'] as num).toInt();
      callback(got, total);
      if (got >= total) _progressCallbacks.remove(taskId);
    });
  }

  @override
  Future<void> deleteRemote(String relPath) async {
    final handle = await _ensureConnected();
    await _channel.invokeMethod<void>('deleteRemote', {
      'handle': handle,
      'relPath': relPath,
    });
  }

  @override
  Future<void> close() async {
    final sub = _progressSub;
    _progressSub = null;
    await sub?.cancel();
    _progressCallbacks.clear();

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
