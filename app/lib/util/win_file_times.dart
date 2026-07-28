// Reading and restoring a file's timestamps on Windows.
//
// Dart has no API for setting mtime (let alone creation time), so this is a
// direct Win32 call. It exists for one reason: rewriting a file's tags must
// not change what Explorer -- or a "sort by date" in any other player --
// shows for that file.
//
// Measured on the NAS share this library lives on (\\murkyserver\drop, SMB
// to Samba, 2026-07-27): the share reports creation time as EQUAL to
// modified time, and a rename preserves both. So restoring the write time
// there is sufficient. On a local NTFS volume creation time is genuinely
// independent, which is why [setFileTimes] restores all three rather than
// only the write time -- correct in both places, no per-volume special case.
//
// Last modified: 2026-07-27--2010

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// A file's three Windows timestamps, as raw FILETIME ticks (100-nanosecond
/// intervals since 1601-01-01 UTC). Kept as raw ticks rather than DateTime so
/// a restore is byte-exact -- no rounding through millisecond precision.
class FileTimes {
  final int creation;
  final int lastAccess;
  final int lastWrite;
  const FileTimes(this.creation, this.lastAccess, this.lastWrite);

  static const int _ticksPerMs = 10000;
  static final int _epochOffset =
      DateTime.utc(1970).difference(DateTime.utc(1601)).inMilliseconds *
      _ticksPerMs;

  DateTime get lastWriteUtc => DateTime.fromMillisecondsSinceEpoch(
    (lastWrite - _epochOffset) ~/ _ticksPerMs,
    isUtc: true,
  );

  DateTime get creationUtc => DateTime.fromMillisecondsSinceEpoch(
    (creation - _epochOffset) ~/ _ticksPerMs,
    isUtc: true,
  );

  @override
  String toString() => 'FileTimes(created $creationUtc, written $lastWriteUtc)';
}

typedef _CreateFileWNative =
    IntPtr Function(
      Pointer<Utf16>,
      Uint32,
      Uint32,
      Pointer<Void>,
      Uint32,
      Uint32,
      IntPtr,
    );
typedef _CreateFileWDart =
    int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int);

typedef _FileTimeNative =
    Int32 Function(IntPtr, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>);
typedef _FileTimeDart =
    int Function(int, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>);

typedef _CloseHandleNative = Int32 Function(IntPtr);
typedef _CloseHandleDart = int Function(int);

final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

final _createFileW = _kernel32
    .lookupFunction<_CreateFileWNative, _CreateFileWDart>('CreateFileW');
final _getFileTime = _kernel32.lookupFunction<_FileTimeNative, _FileTimeDart>(
  'GetFileTime',
);
final _setFileTime = _kernel32.lookupFunction<_FileTimeNative, _FileTimeDart>(
  'SetFileTime',
);
final _closeHandle = _kernel32
    .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');

const int _genericRead = 0x80000000;
const int _fileWriteAttributes = 0x0100;
const int _shareAll = 0x00000007; // read | write | delete
const int _openExisting = 3;
const int _fileAttributeNormal = 0x80;
const int _invalidHandle = -1;

int _open(String path, int access) {
  final p = path.toNativeUtf16();
  try {
    return _createFileW(
      p,
      access,
      _shareAll,
      nullptr,
      _openExisting,
      _fileAttributeNormal,
      0,
    );
  } finally {
    malloc.free(p);
  }
}

/// Reads [path]'s timestamps. Null on any failure (a caller that can't read
/// the times must not go on to rewrite the file).
FileTimes? getFileTimes(String path) {
  if (!Platform.isWindows) return null;
  final h = _open(path, _genericRead);
  if (h == _invalidHandle) return null;
  final buf = calloc<Uint64>(3);
  try {
    final ok = _getFileTime(h, buf, buf + 1, buf + 2);
    if (ok == 0) return null;
    return FileTimes(buf[0], buf[1], buf[2]);
  } finally {
    calloc.free(buf);
    _closeHandle(h);
  }
}

/// Restores [times] onto [path]. Returns false if the write was rejected --
/// which the caller should surface, not swallow: a file left with today's
/// date is exactly the damage this is here to prevent.
bool setFileTimes(String path, FileTimes times) {
  if (!Platform.isWindows) return false;
  final h = _open(path, _fileWriteAttributes);
  if (h == _invalidHandle) return false;
  final buf = calloc<Uint64>(3);
  try {
    buf[0] = times.creation;
    buf[1] = times.lastAccess;
    buf[2] = times.lastWrite;
    return _setFileTime(h, buf, buf + 1, buf + 2) != 0;
  } finally {
    calloc.free(buf);
    _closeHandle(h);
  }
}
