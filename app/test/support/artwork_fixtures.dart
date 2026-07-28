// Shared test scaffolding for the artwork module: fixture loading and fake
// [ArtFetch] implementations.
//
// NOTHING in here (or in anything that uses it) may touch the network. The
// JSON under `test/fixtures/artwork/` was written by hand from the providers'
// documented response shapes; the fakes below are the only "transport" the
// artwork tests ever see.
//
// Last modified: 2026-07-25--2113

import 'dart:async';
import 'dart:io';

import 'package:fooplayer_app/artwork/providers.dart';
import 'package:path/path.dart' as p;

/// `flutter test` runs with the package root as cwd, so fixtures resolve
/// relative to it.
String artFixturePath(String name) =>
    p.join('test', 'fixtures', 'artwork', name);

/// Reads a fixture file verbatim. Throws loudly if it's missing -- a silently
/// empty fixture would make a test pass for the wrong reason.
String loadArtFixture(String name) {
  final f = File(artFixturePath(name));
  if (!f.existsSync()) {
    throw StateError('missing artwork fixture: ${f.absolute.path}');
  }
  return f.readAsStringSync();
}

/// One recorded call made through a [FakeArtFetch].
class FetchCall {
  final Uri url;
  final Map<String, String> headers;

  FetchCall(this.url, Map<String, String>? headers)
    : headers = Map.unmodifiable(headers ?? const {});

  @override
  String toString() => 'FetchCall($url, $headers)';
}

/// Fake transport driven by a host -> response map.
///
/// Anything not in the map is answered 404, so a test that accidentally
/// reaches for an unstubbed endpoint fails as "no candidates" rather than
/// quietly opening a socket.
class FakeArtFetch {
  final Map<String, ArtHttpResponse Function(Uri url)> _byHost;
  final calls = <FetchCall>[];

  FakeArtFetch(Map<String, ArtHttpResponse Function(Uri url)> byHost)
    : _byHost = byHost;

  /// Convenience: map each host directly to a 200 + body string.
  factory FakeArtFetch.bodies(Map<String, String> byHost) => FakeArtFetch({
    for (final e in byHost.entries)
      e.key: (_) => ArtHttpResponse(statusCode: 200, body: e.value),
  });

  ArtFetch get fetch => _call;

  Future<ArtHttpResponse> _call(Uri url, {Map<String, String>? headers}) async {
    calls.add(FetchCall(url, headers));
    final handler = _byHost[url.host];
    if (handler == null) {
      return const ArtHttpResponse(statusCode: 404, body: 'not found');
    }
    return handler(url);
  }

  /// The single call made to [host]; fails the caller if there wasn't exactly
  /// one.
  FetchCall callTo(String host) => calls.singleWhere((c) => c.url.host == host);

  bool wasCalled(String host) => calls.any((c) => c.url.host == host);
}

/// An [ArtFetch] that always throws -- stands in for "no network at all".
Future<ArtHttpResponse> throwingArtFetch(
  Uri url, {
  Map<String, String>? headers,
}) => Future<ArtHttpResponse>.error(
  const SocketException('Failed host lookup (test)'),
);

/// Deterministic clock + sleep pair for driving [RateLimiter] without
/// spending real seconds. Every `sleep(d)` advances the fake clock by `d` and
/// is recorded.
class FakeClock {
  DateTime _now;
  final waits = <Duration>[];

  FakeClock([DateTime? start]) : _now = start ?? DateTime.utc(2026);

  DateTime now() => _now;

  Future<void> sleep(Duration d) async {
    waits.add(d);
    _now = _now.add(d);
  }

  /// Advance without sleeping (simulates time passing during a request).
  void advance(Duration d) => _now = _now.add(d);
}
