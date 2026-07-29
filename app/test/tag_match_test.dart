// Proposing corrected tags: scoring, parsing, and the picker's restraint.
//
// The artwork pass may auto-apply a confident cover, because a wrong cover is
// embarrassing. Nothing here applies anything: a wrong title rewrites the
// file, and this project exists because something else did that unasked. So
// the tests are about what it refuses to decide as much as what it ranks.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/providers.dart'
    show ArtHttpResponse, RateLimiter;
import 'package:fooplayer_app/metadata/tag_candidate.dart';
import 'package:fooplayer_app/metadata/tag_providers.dart';
import 'package:fooplayer_app/metadata/tag_scoring.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/tag_match_dialog.dart';

TagCandidate _c({
  String title = 'A Song',
  String artist = 'An Artist',
  String album = 'An Album',
  int? durationMs,
  String id = 'x',
}) => TagCandidate(
  title: title,
  artist: artist,
  album: album,
  durationMs: durationMs,
  id: id,
);

void main() {
  group('duration is the field a human cannot eyeball', () {
    test('within a second and a half is a full match', () {
      expect(durationSimilarity(214000, 214800), 1);
    });

    test('five seconds out is a different recording', () {
      expect(durationSimilarity(214000, 219500), 0);
    });

    test('an unknown duration neither helps nor punishes', () {
      expect(durationSimilarity(null, 214000), 0.5);
      expect(durationSimilarity(214000, null), 0.5);
      expect(durationSimilarity(214000, 0), 0.5);
    });

    test('it separates two recordings the text cannot', () {
      // Both called "Intro" by the same artist -- exactly the case where
      // titles and artists are useless and length is the whole answer.
      const q = TagQuery(title: 'Intro', artist: 'Jay-Z', durationMs: 95000);
      final ranked = rankTagCandidates(q, [
        _c(title: 'Intro', artist: 'Jay-Z', durationMs: 240000, id: 'long'),
        _c(title: 'Intro', artist: 'Jay-Z', durationMs: 95500, id: 'short'),
      ]);
      expect(ranked.first.candidate.id, 'short');
    });
  });

  group('ranking', () {
    test('an exact match scores very likely', () {
      const q = TagQuery(
        title: 'Teardrop',
        artist: 'Massive Attack',
        album: 'Mezzanine',
        durationMs: 330000,
      );
      final ranked = rankTagCandidates(q, [
        _c(
          title: 'Teardrop',
          artist: 'Massive Attack',
          album: 'Mezzanine',
          durationMs: 330000,
        ),
      ]);
      expect(ranked.first.score, greaterThanOrEqualTo(85));
      expect(ranked.first.confidence, 'Very likely');
    });

    test('a missing album on either side is not held against a candidate', () {
      // Half this library has junk or no album, which is the point of the
      // feature -- punishing that would rank the right answer last.
      const q = TagQuery(title: 'Teardrop', artist: 'Massive Attack');
      final ranked = rankTagCandidates(q, [
        _c(title: 'Teardrop', artist: 'Massive Attack', album: 'Mezzanine'),
      ]);
      expect(ranked.first.score, greaterThan(70));
    });

    test('duplicates from several releases collapse', () {
      const q = TagQuery(title: 'A Song', artist: 'An Artist');
      final ranked = rankTagCandidates(q, [
        _c(id: 'same'),
        _c(id: 'same'),
        _c(id: 'other', album: 'Greatest Hits'),
      ]);
      expect(ranked, hasLength(2));
    });

    test('ordering is total, so the list never shuffles between runs', () {
      const q = TagQuery(title: 'A Song', artist: 'An Artist');
      final input = [
        _c(id: 'b', title: 'A Song (Remastered 2011)'),
        _c(id: 'a', title: 'A Song'),
      ];
      expect(
        rankTagCandidates(q, input).map((s) => s.candidate.id),
        rankTagCandidates(q, input.reversed).map((s) => s.candidate.id),
      );
    });
  });

  group('what it refuses to decide', () {
    test('nothing is pre-selected when two candidates are close', () {
      const q = TagQuery(title: 'A Song', artist: 'An Artist');
      final ranked = rankTagCandidates(q, [
        _c(id: 'a', album: 'Album One'),
        _c(id: 'b', album: 'Album Two'),
      ]);
      expect(
        bestTagGuess(ranked),
        isNull,
        reason: 'an ambiguous pair is the user\'s call, not a rounding error',
      );
    });

    test('a weak best match is not pre-selected either', () {
      const q = TagQuery(title: 'Completely Different', artist: 'Someone Else');
      final ranked = rankTagCandidates(q, [_c()]);
      expect(bestTagGuess(ranked), isNull);
    });

    test('a clear winner is pre-selected', () {
      const q = TagQuery(
        title: 'Teardrop',
        artist: 'Massive Attack',
        durationMs: 330000,
      );
      final ranked = rankTagCandidates(q, [
        _c(
          id: 'right',
          title: 'Teardrop',
          artist: 'Massive Attack',
          album: 'Mezzanine',
          durationMs: 330000,
        ),
        _c(id: 'wrong', title: 'Unrelated', artist: 'Nobody'),
      ]);
      expect(bestTagGuess(ranked)!.candidate.id, 'right');
    });
  });

  group('the MusicBrainz query', () {
    test('asks for recordings, with the title and artist quoted', () {
      final uri = musicBrainzRecordingUri(
        const TagQuery(title: 'Teardrop', artist: 'Massive Attack'),
      );
      expect(uri.host, 'musicbrainz.org');
      expect(uri.path, '/ws/2/recording');
      expect(uri.queryParameters['query'],
          'recording:"Teardrop" AND artist:"Massive Attack"');
      expect(uri.queryParameters['fmt'], 'json');
    });

    test('lucene syntax in a title cannot change what is asked', () {
      final uri = musicBrainzRecordingUri(
        const TagQuery(title: 'Where Is My Mind? (A:B)', artist: 'Pixies'),
      );
      expect(uri.queryParameters['query'], contains(r'\?'));
      expect(uri.queryParameters['query'], contains(r'\('));
    });

    test('one recording on three releases becomes three candidates', () async {
      // Album and track number differ per release, and those are exactly the
      // fields being corrected -- so each release is its own proposal.
      final body = jsonEncode({
        'recordings': [
          {
            'id': 'rec-1',
            'title': 'Teardrop',
            'length': 330000,
            'artist-credit': [
              {'name': 'Massive Attack'},
            ],
            'releases': [
              {
                'title': 'Mezzanine',
                'date': '1998-04-20',
                'media': [
                  {
                    'track': [
                      {'number': '4'},
                    ],
                  },
                ],
              },
              {'title': 'Singles 90/98', 'date': '1998'},
              {'title': 'Collected', 'date': '2006'},
            ],
          },
        ],
      });

      final got = await searchMusicBrainzRecordings(
        const TagQuery(title: 'Teardrop', artist: 'Massive Attack'),
        limiter: RateLimiter(minInterval: Duration.zero),
        fetch: (uri, {headers}) async =>
            ArtHttpResponse(statusCode: 200, body: body),
      );

      expect(got, hasLength(3));
      expect(got.first.album, 'Mezzanine');
      expect(got.first.trackNumber, '4');
      expect(got.first.year, 1998);
      expect(got.first.durationMs, 330000);
      expect(got.first.artist, 'Massive Attack');
    });

    test('every failure degrades to no proposals, never an exception',
        () async {
      final limiter = RateLimiter(minInterval: Duration.zero);
      const q = TagQuery(title: 'x', artist: 'y');

      expect(
        await searchMusicBrainzRecordings(q,
            limiter: limiter,
            fetch: (uri, {headers}) async =>
                const ArtHttpResponse(statusCode: 503, body: '')),
        isEmpty,
      );
      expect(
        await searchMusicBrainzRecordings(q,
            limiter: limiter,
            fetch: (uri, {headers}) async =>
                const ArtHttpResponse(statusCode: 200, body: 'not json')),
        isEmpty,
      );
      expect(
        await searchMusicBrainzRecordings(q,
            limiter: limiter,
            fetch: (uri, {headers}) async => throw const SocketishError()),
        isEmpty,
      );
      expect(
        await searchMusicBrainzRecordings(const TagQuery(),
            limiter: limiter,
            fetch: (uri, {headers}) async =>
                throw StateError('must not be called')),
        isEmpty,
      );
    });
  });

  group('the picker', () {
    Future<void> pump(
      WidgetTester tester,
      Future<List<TagCandidate>> Function(TagQuery) search,
    ) => tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: TagMatchDialog(
            query: const TagQuery(
              title: 'Teardrop',
              artist: 'Massive Attack',
              durationMs: 330000,
            ),
            search: search,
          ),
        ),
      ),
    );

    testWidgets('says it is searching, then lists what it found', (
      tester,
    ) async {
      await pump(
        tester,
        (q) async => [
          _c(
            title: 'Teardrop',
            artist: 'Massive Attack',
            album: 'Mezzanine',
            durationMs: 330000,
          ),
        ],
      );
      expect(find.byKey(const Key('tag-match-searching')), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tag-match-row-0')), findsOneWidget);
      expect(find.text('Very likely'), findsOneWidget);
    });

    testWidgets('finding nothing says so, and changes nothing', (
      tester,
    ) async {
      await pump(tester, (q) async => const []);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('tag-match-empty')), findsOneWidget);
      final use = tester.widget<FilledButton>(
        find.byKey(const Key('tag-match-use')),
      );
      expect(use.onPressed, isNull, reason: 'nothing to apply');
    });
  });
}

/// Stands in for a socket failure without importing dart:io into a widget
/// test.
class SocketishError implements Exception {
  const SocketishError();
}
