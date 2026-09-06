import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pahe_cat/models/anime.dart';
import 'package:pahe_cat/models/download_item.dart';
import 'package:pahe_cat/models/episode.dart';
import 'package:pahe_cat/models/stream_source.dart';
import 'package:pahe_cat/models/watch_progress.dart';
import 'package:pahe_cat/services/animepahe_api.dart';
import 'package:pahe_cat/services/download_manager.dart';
import 'package:pahe_cat/services/providers.dart';
import 'package:pahe_cat/screens/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

DownloadItem _item({
  String anime = 'Test',
  int ep = 1,
  int total = 12,
  String epTitle = '',
  String quality = '720p',
  String audio = 'sub',
}) =>
    DownloadItem(
      id: 'x',
      animeTitle: anime,
      episodeNumber: ep,
      totalEpisodes: total,
      episodeTitle: epTitle,
      quality: quality,
      audio: audio,
      sourceUrl: 'https://example.com/v.mp4',
    );

void main() {
  group('play page parsing', () {
    test('reads sources regardless of attribute order', () {
      const a = '''
        <a data-src="https://kwik.si/e/aaa" data-resolution="720"
           data-audio="jpn" data-filesize="250MB">720p</a>
      ''';
      // Same link, attributes reordered — the old positional regex missed this.
      const b = '''
        <a data-audio="jpn" data-filesize="250MB"
           data-resolution="720" data-src="https://kwik.si/e/aaa">720p</a>
      ''';
      final fromA = AnimePaheApi.parsePlayPage(a);
      final fromB = AnimePaheApi.parsePlayPage(b);

      expect(fromA, hasLength(1));
      expect(fromB, hasLength(1));
      expect(fromA.first.quality, '720p');
      expect(fromB.first.quality, '720p');
      expect(fromB.first.kwikUrl, 'https://kwik.si/e/aaa');
    });

    test('separates sub and dub and puts sub first', () {
      const html = '''
        <a data-src="https://kwik.si/e/dub1" data-resolution="1080" data-audio="eng">1080p</a>
        <a data-src="https://kwik.si/e/sub1" data-resolution="720" data-audio="jpn">720p</a>
      ''';
      final s = AnimePaheApi.parsePlayPage(html);
      expect(s, hasLength(2));
      expect(s.first.isDub, isFalse, reason: 'sub should sort ahead of dub');
      expect(s.first.audioLabel, 'SUB');
      expect(s.last.audioLabel, 'DUB');
    });

    test('orders qualities high to low within the same audio track', () {
      const html = '''
        <a data-src="https://kwik.si/e/a" data-resolution="360" data-audio="jpn">360p</a>
        <a data-src="https://kwik.si/e/b" data-resolution="1080" data-audio="jpn">1080p</a>
        <a data-src="https://kwik.si/e/c" data-resolution="720" data-audio="jpn">720p</a>
      ''';
      expect(
        AnimePaheApi.parsePlayPage(html).map((e) => e.quality).toList(),
        ['1080p', '720p', '360p'],
      );
    });

    test('recovers quality from link text when attributes are missing', () {
      const html = '<a href="https://kwik.si/e/xyz">1080p (1.2GB) eng</a>';
      final s = AnimePaheApi.parsePlayPage(html);
      expect(s, hasLength(1));
      expect(s.first.quality, '1080p');
      expect(s.first.isDub, isTrue);
    });

    test('falls back to scanning raw text for JS-built links', () {
      // No anchors at all — links only exist inside a script.
      const html = '''
        <script>
          var opts = [{"src":"https://kwik.si/e/js1","label":"720p jpn"}];
        </script>
      ''';
      final s = AnimePaheApi.parsePlayPage(html);
      expect(s, hasLength(1));
      expect(s.first.kwikUrl, 'https://kwik.si/e/js1');
      expect(s.first.quality, '720p');
    });

    test('dedupes a link that appears in several places', () {
      const html = '''
        <a data-src="https://kwik.si/e/same" data-resolution="720" data-audio="jpn">720p</a>
        <button data-src="https://kwik.si/e/same" data-resolution="720" data-audio="jpn">720p</button>
      ''';
      expect(AnimePaheApi.parsePlayPage(html), hasLength(1));
    });

    test('unknown quality sorts last instead of throwing', () {
      const html = '''
        <a data-src="https://kwik.si/e/weird" data-audio="jpn">Download</a>
        <a data-src="https://kwik.si/e/ok" data-resolution="720" data-audio="jpn">720p</a>
      ''';
      final s = AnimePaheApi.parsePlayPage(html);
      expect(s, hasLength(2));
      expect(s.first.quality, '720p');
      expect(s.last.quality, 'unknown');
    });

    test('returns nothing for an empty or unrelated page', () {
      expect(AnimePaheApi.parsePlayPage(''), isEmpty);
      expect(AnimePaheApi.parsePlayPage('<html><body>nope</body></html>'), isEmpty);
    });

    test('tolerates a kwik domain change', () {
      const html = '<a data-src="https://kwik.cx/f/abc" data-resolution="480" data-audio="jpn">480p</a>';
      expect(AnimePaheApi.parsePlayPage(html), hasLength(1));
    });
  });

  group('airing feed', () {
    test('maps anime_* keys so cards are not blank', () {
      // The bug: this shape through Anime.fromJson produced empty everything.
      final a = Anime.fromAiring({
        'anime_title': 'Frieren',
        'anime_session': 'sess-123',
        'snapshot': 'https://example.com/snap.jpg',
        'episode': 12,
      });
      expect(a.title, 'Frieren');
      expect(a.session, 'sess-123');
      expect(a.poster, 'https://example.com/snap.jpg');
    });

    test('prefers a real poster over the episode snapshot', () {
      final a = Anime.fromAiring({
        'anime_title': 'X',
        'anime_session': 's',
        'poster': 'https://example.com/poster.jpg',
        'snapshot': 'https://example.com/snap.jpg',
      });
      expect(a.poster, 'https://example.com/poster.jpg');
    });
  });

  group('download filenames', () {
    test('pads to the width of the series episode count', () {
      expect(
        DownloadManager.buildFileName(_item(anime: 'Bleach', ep: 7, total: 24)),
        'Bleach - EP07 [720p][SUB].mp4',
      );
      expect(
        DownloadManager.buildFileName(_item(anime: 'Naruto', ep: 7, total: 700)),
        'Naruto - EP007 [720p][SUB].mp4',
      );
      expect(
        DownloadManager.buildFileName(
            _item(anime: 'One Piece', ep: 7, total: 1122)),
        'One Piece - EP0007 [720p][SUB].mp4',
      );
    });

    test('One Piece episodes sort correctly as strings', () {
      final names = [999, 1000, 1, 1122]
          .map((n) => DownloadManager.buildFileName(
              _item(anime: 'One Piece', ep: n, total: 1122)))
          .toList()
        ..sort();
      expect(
        names.map((n) => RegExp(r'EP(\d+)').firstMatch(n)!.group(1)).toList(),
        ['0001', '0999', '1000', '1122'],
      );
    });

    test('falls back to the episode number when the count is unknown', () {
      // Ongoing series report 0 episodes; padding must not truncate.
      expect(
        DownloadManager.buildFileName(
            _item(anime: 'Ongoing', ep: 1050, total: 0)),
        'Ongoing - EP1050 [720p][SUB].mp4',
      );
    });

    test('includes the episode title when present', () {
      expect(
        DownloadManager.buildFileName(
            _item(anime: 'Naruto', ep: 1, total: 220, epTitle: 'Homecoming')),
        'Naruto - EP001 - Homecoming [720p][SUB].mp4',
      );
    });

    test('strips characters that are illegal in filenames', () {
      final name = DownloadManager.buildFileName(
          _item(anime: 'Re:Zero / Season 2', ep: 3, total: 25));
      expect(name.contains(':'), isFalse);
      expect(name.contains('/'), isFalse);
      expect(name, 'ReZero Season 2 - EP03 [720p][SUB].mp4');
    });
  });

  test('StreamSource labels dub sources correctly', () {
    const dub = StreamSource(
      quality: '720p',
      kwikUrl: 'https://kwik.si/e/abc',
      audio: 'eng',
      fileSize: '250 MB',
    );
    const sub = StreamSource(
      quality: '1080p',
      kwikUrl: 'https://kwik.si/e/xyz',
      audio: 'jpn',
      fileSize: '',
    );

    expect(dub.isDub, isTrue);
    expect(dub.audioLabel, 'DUB');
    expect(sub.isDub, isFalse);
    expect(sub.audioLabel, 'SUB');
  });

  test('WatchProgress computes fraction and survives a round trip', () {
    final p = WatchProgress(
      animeSession: 's1',
      animeTitle: 'Test Anime',
      animePoster: 'https://example.com/p.jpg',
      lastEpisode: 6,
      totalEpisodes: 24,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );

    expect(p.progressFraction, closeTo(0.25, 0.0001));
    expect(p.progressLabel, '6 / 24 ep');

    final restored = WatchProgress.fromMap(p.toMap());
    expect(restored.animeSession, p.animeSession);
    expect(restored.lastEpisode, p.lastEpisode);
    expect(restored.updatedAt, p.updatedAt);
  });

  test('WatchProgress handles zero total episodes without dividing by zero', () {
    final p = WatchProgress(
      animeSession: 's2',
      animeTitle: 'Unknown',
      animePoster: '',
      lastEpisode: 0,
      totalEpisodes: 0,
      updatedAt: DateTime.now(),
    );
    expect(p.progressFraction, 0);
  });
  group('play page pairing', () {
    // The markup below is the shape animepahe actually serves: the stream
    // buttons carry the metadata, the download anchors carry the size and the
    // only link that yields a file.
    const realish = '''
      <button type="button" data-src="https://kwik.cx/e/aaa" data-url="https://kwik.cx/e/aaa"
              data-fansub="SubsPlease" data-resolution="360" data-audio="jpn"
              class="dropdown-item">SubsPlease &middot; 360p</button>
      <button type="button" data-src="https://kwik.cx/e/bbb" data-url="https://kwik.cx/e/bbb"
              data-fansub="SubsPlease" data-resolution="1080" data-audio="jpn"
              class="dropdown-item">SubsPlease &middot; 1080p</button>
      <div class="dropdown-menu" id="pickDownload">
        <a href="https://pahe.win/YlPTN" class="dropdown-item">SubsPlease &middot; 360p (20MB)</a>
        <a href="https://pahe.win/TKcqw" class="dropdown-item">SubsPlease &middot; 1080p (70MB)</a>
      </div>
    ''';

    test('attaches each download link and size to its stream', () {
      final s = AnimePaheApi.parsePlayPage(realish);
      expect(s.length, 2);
      final hd = s.firstWhere((e) => e.quality == '1080p');
      expect(hd.kwikUrl, 'https://kwik.cx/e/bbb');
      expect(hd.downloadUrl, 'https://pahe.win/TKcqw');
      expect(hd.fileSize, '70MB');
      expect(hd.canStream, isTrue);
      expect(hd.canDownload, isTrue);
    });

    test('a stream with no matching download is still streamable', () {
      final s = AnimePaheApi.parsePlayPage(
          '<button data-src="https://kwik.cx/e/x" data-resolution="720" '
          'data-audio="jpn"></button>');
      expect(s.single.canStream, isTrue);
      expect(s.single.canDownload, isFalse);
    });

    test('pairs dub links to dub streams, not to the sub at that quality', () {
      const dual = '''
        <button data-src="https://kwik.cx/e/sub" data-resolution="720" data-audio="jpn"></button>
        <button data-src="https://kwik.cx/e/dub" data-resolution="720" data-audio="eng"></button>
        <a href="https://pahe.win/subfile" class="dropdown-item">Group &middot; 720p (100MB)</a>
        <a href="https://pahe.win/dubfile" class="dropdown-item">Group &middot; 720p (200MB) eng</a>
      ''';
      final s = AnimePaheApi.parsePlayPage(dual);
      final sub = s.firstWhere((e) => !e.isDub);
      final dub = s.firstWhere((e) => e.isDub);
      expect(sub.downloadUrl, 'https://pahe.win/subfile');
      expect(dub.downloadUrl, 'https://pahe.win/dubfile');
    });
  });

  group('resume point', () {
    WatchProgress make({int last = 0, int resumeEp = 0, double pos = 0}) =>
        WatchProgress(
          animeSession: 's',
          animeTitle: 't',
          animePoster: '',
          lastEpisode: last,
          totalEpisodes: 12,
          resumeEpisode: resumeEp,
          resumePosition: pos,
          updatedAt: DateTime(2026),
        );

    test('offers episode 1 when nothing has been watched', () {
      expect(make().continueEpisode, 1);
    });

    test('opening an episode points there, not at the previous one', () {
      // The reported bug: jumping to episode 4 still offered episode 1.
      expect(make(last: 1, resumeEp: 4, pos: 0.01).continueEpisode, 4);
    });

    test('resumes a part-watched episode and shows how far in', () {
      final p = make(last: 3, resumeEp: 4, pos: 0.43);
      expect(p.continueEpisode, 4);
      expect(p.hasPartialEpisode, isTrue);
      expect(p.resumeLabel, 'EP 4 · 43%');
    });

    test('a finished episode moves on to the next one', () {
      final p = make(last: 4, resumeEp: 4, pos: 0.95);
      expect(p.continueEpisode, 5);
      expect(p.hasPartialEpisode, isFalse);
    });

    test('rewatching an earlier episode does not lose the series position', () {
      // lastEpisode is the furthest reached, so it stays put.
      final p = make(last: 9, resumeEp: 2, pos: 0.5);
      expect(p.lastEpisode, 9);
      expect(p.continueEpisode, 2);
    });

    test('the bar moves during the first episode, not only after it', () {
      // Counting finished episodes alone left the bar on zero for the whole
      // of episode 1, which reads as nothing having been recorded.
      final started = make(last: 0, resumeEp: 1, pos: 0.5);
      expect(started.progressFraction, closeTo(0.5 / 12, 0.0001));
    });

    test('a part-watched episode adds to the finished ones', () {
      final p = make(last: 3, resumeEp: 4, pos: 0.5);
      expect(p.progressFraction, closeTo(3.5 / 12, 0.0001));
    });

    test('rewatching an earlier episode does not inflate the bar', () {
      // resumeEpisode is behind lastEpisode here, so it must not be added on
      // top of the episodes already finished.
      final p = make(last: 9, resumeEp: 2, pos: 0.5);
      expect(p.progressFraction, closeTo(9 / 12, 0.0001));
    });

    test('never exceeds a full bar', () {
      final p = make(last: 12, resumeEp: 13, pos: 0.9);
      expect(p.progressFraction, 1.0);
    });

    test('survives a round trip through the database map', () {
      final p = make(last: 5, resumeEp: 6, pos: 0.25);
      final back = WatchProgress.fromMap(p.toMap());
      expect(back.resumeEpisode, 6);
      expect(back.resumePosition, closeTo(0.25, 0.0001));
      expect(back.lastEpisode, 5);
    });

    test('reads rows written before the resume columns existed', () {
      final legacy = {
        'anime_session': 's',
        'anime_title': 't',
        'anime_poster': '',
        'last_episode': 3,
        'total_episodes': 12,
        'updated_at': DateTime(2026).millisecondsSinceEpoch,
      };
      final p = WatchProgress.fromMap(legacy);
      expect(p.resumeEpisode, 0);
      expect(p.continueEpisode, 4);
    });
  });

  group('episode pages', () {
    EpisodesState stateFor({required int total, int perPage = 30}) {
      return EpisodesState(
        episodes: [
          for (var n = 1; n <= total; n++)
            Episode(
              session: 's$n',
              animeSession: 'a',
              number: n,
              title: '',
              snapshot: '',
              audio: 'jpn',
              duration: '',
              fansub: '',
              createdAt: '',
            ),
        ],
        perPage: perPage,
        total: total,
        totalPages: (total / perPage).ceil(),
      );
    }

    test('a page spans exactly the page size, not a rounded-up page count',
        () {
      // With a 30-per-page feed the old rounding produced spans of 120 and a
      // dropdown that read "EP 1-120" while holding 30.
      final ranges = stateFor(total: 250).ranges;
      expect(ranges.length, 5);
      expect(ranges[0].label, 'EP 1–50');
      expect(ranges[1].label, 'EP 51–100');
      expect(ranges.last.label, 'EP 201–250'); // short, not overshooting
    });

    test('the last page is short rather than overshooting the series', () {
      final ranges = stateFor(total: 60).ranges;
      expect(ranges.length, 2);
      expect(ranges.last.label, 'EP 51–60');
    });

    test('derives which API pages hold a range', () {
      final r = stateFor(total: 250).ranges[1]; // EP 51-100, 30 per page
      expect(r.firstPage, 2); // episodes 31-60
      expect(r.lastPage, 4); // episodes 91-120
    });

    test('a series inside one page offers no dropdown', () {
      expect(stateFor(total: 12).ranges, isEmpty);
      expect(stateFor(total: 50).ranges, isEmpty);
    });

    test('only the selected range is shown, not a straddling API page', () {
      // Page 2 carries episodes 31-60, so the first range must not show the
      // 51-60 tail under a heading that stops at 50.
      final base = stateFor(total: 250);
      final state = base.copyWith(selected: base.ranges.first);
      expect(state.visibleEpisodes.first.number, 1);
      expect(state.visibleEpisodes.last.number, 50);
      expect(state.visibleEpisodes.length, 50);
    });

    test('splits a page into fixed blocks of 25', () {
      final base = stateFor(total: 250);
      final state = base.copyWith(selected: base.ranges.first);
      final chunks = state.downloadChunks;
      expect(chunks.length, 2);
      expect(chunks.first.first.number, 1);
      expect(chunks.first.last.number, 25);
      expect(chunks.last.first.number, 26);
      expect(chunks.last.last.number, 50);
    });

    test('the block size stays at 25 whatever the page holds', () {
      final base = stateFor(total: 250);
      final second = base.copyWith(selected: base.ranges[1]); // EP 51-100
      expect(second.downloadChunks.map((c) => c.length), [25, 25]);
      expect(second.downloadChunks.first.first.number, 51);
    });

    test('a short last block is not padded out', () {
      final chunks = stateFor(total: 60).downloadChunks;
      expect(chunks.map((c) => c.length), [25, 25, 10]);
    });
  });

  // The settings screen shipped with a Material that was given both a `shape`
  // and a `borderRadius`. Material asserts that only one of them describes its
  // outline, so the whole tab threw on build — and nothing here ever built it,
  // which is why that reached a release. Pumping it is the guard.
  group('settings screen', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets('builds without throwing', (tester) async {
      await tester.pumpWidget(const ProviderScope(
        child: MaterialApp(home: SettingsScreen()),
      ));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('shows the version the release is tagged with',
        (tester) async {
      await tester.pumpWidget(const ProviderScope(
        child: MaterialApp(home: SettingsScreen()),
      ));
      await tester.pump();

      expect(find.text(kAppVersion), findsOneWidget);
    });
  });
}
