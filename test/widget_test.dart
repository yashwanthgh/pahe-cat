import 'package:flutter_test/flutter_test.dart';
import 'package:pahe_boy/models/anime.dart';
import 'package:pahe_boy/models/download_item.dart';
import 'package:pahe_boy/models/stream_source.dart';
import 'package:pahe_boy/models/watch_progress.dart';
import 'package:pahe_boy/services/animepahe_api.dart';
import 'package:pahe_boy/services/download_manager.dart';

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
}
