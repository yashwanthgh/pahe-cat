import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import '../models/anime.dart';
import '../models/episode.dart';
import '../models/stream_source.dart';
import 'cf_session.dart';
import 'domain_resolver.dart';
import 'preview_data.dart';

/// Thrown when the play page yields no usable sources, so the UI can tell the
/// difference between "no dub exists" and "the page layout changed".
class NoSourcesFound implements Exception {
  final String playUrl;
  NoSourcesFound(this.playUrl);
  @override
  String toString() => 'No playable sources found on $playUrl';
}

class AnimePaheApi {
  static final AnimePaheApi _i = AnimePaheApi._();
  AnimePaheApi._();
  factory AnimePaheApi() => _i;

  /// Requests run inside the cleared WebView; see [CfSession]. The domain can
  /// change between calls, so each URL is built from the resolved host.
  Future<Map<String, dynamic>> _getJson(Map<String, String> query) async {
    final uri = Uri.parse('${DomainResolver.base}/api')
        .replace(queryParameters: query);
    final body = await _fetchWithBackoff(uri.toString());
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// Retries a rate-limited request instead of surfacing it as a dead end.
  ///
  /// animepahe answers bursts with 429; a short escalating wait clears it,
  /// whereas failing outright left the episode list permanently empty.
  Future<String> _fetchWithBackoff(String url, {bool asJson = true}) async {
    const delays = [
      Duration(milliseconds: 700),
      Duration(seconds: 2),
      Duration(seconds: 5),
    ];
    Object? last;
    for (var attempt = 0; attempt <= delays.length; attempt++) {
      try {
        return await CfSession().fetch(url, asJson: asJson);
      } catch (e) {
        last = e;
        final rateLimited = e.toString().contains('429');
        if (!rateLimited || attempt == delays.length) rethrow;
        await Future.delayed(delays[attempt]);
      }
    }
    throw Exception(last ?? 'request failed');
  }

  Future<List<Anime>> search(String query) async {
    if (PreviewMode.enabled) return PreviewMode.search(query);
    final r = await _getJson({'m': 'search', 'q': query});
    final data = r['data'] as List? ?? [];
    return data.map((j) => Anime.fromJson(j as Map<String, dynamic>)).toList();
  }

  Future<
      ({
        List<Episode> episodes,
        int totalPages,
        int currentPage,
        int perPage,
        int total
      })> getEpisodes(String animeSession, {int page = 1}) async {
    if (PreviewMode.enabled) {
      final eps = PreviewMode.episodes(animeSession);
      return (
        episodes: eps,
        totalPages: 1,
        currentPage: 1,
        perPage: eps.length,
        total: eps.length,
      );
    }
    final r = await _getJson({
      'm': 'release',
      'id': animeSession,
      'sort': 'episode_asc',
      'page': '$page',
    });
    final data = r['data'] as List? ?? [];
    final episodes = data
        .map((j) => Episode.fromJson(j as Map<String, dynamic>, animeSession))
        .toList();
    return (
      episodes: episodes,
      totalPages: (r['last_page'] as int?) ?? 1,
      currentPage: (r['current_page'] as int?) ?? 1,
      perPage: (r['per_page'] as int?) ?? episodes.length,
      total: (r['total'] as int?) ?? episodes.length,
    );
  }

  /// Walks every page of the release feed. One Piece is 1000+ episodes across
  /// ~40 pages, so pages after the first are fetched concurrently in batches
  /// rather than one at a time.
  Future<List<Episode>> getAllEpisodes(
    String animeSession, {
    void Function(int loaded, int total)? onProgress,
  }) async {
    if (PreviewMode.enabled) return PreviewMode.episodes(animeSession);
    final first = await getEpisodes(animeSession, page: 1);
    final all = [...first.episodes];
    onProgress?.call(all.length, first.totalPages);
    if (first.totalPages <= 1) return all;

    // Sequential with a gap between pages. Five at a time tripped animepahe's
    // rate limiter, and a 429 mid-way left the caller with a partial list.
    for (var page = 2; page <= first.totalPages; page++) {
      final r = await getEpisodes(animeSession, page: page);
      all.addAll(r.episodes);
      onProgress?.call(all.length, first.totalPages);
      if (page < first.totalPages) {
        await Future.delayed(const Duration(milliseconds: 250));
      }
    }

    all.sort((a, b) => a.number.compareTo(b.number));
    return all;
  }

  Future<List<StreamSource>> getSources(
      String animeSession, String episodeSession) async {
    if (PreviewMode.enabled) return PreviewMode.sources;
    final url = '${DomainResolver.base}/play/$animeSession/$episodeSession';
    final html = await _fetchWithBackoff(url, asJson: false);
    final sources = parsePlayPage(html);
    if (sources.isEmpty) {
      // The parser was written without ever seeing this page. Dump enough of
      // it to fix the selectors rather than guess at them again.
      debugPrint('SOURCES: none found on $url (html ${html.length} bytes)');
      for (final m in RegExp(r'kwik[^\s"\x27<>]{0,80}').allMatches(html).take(5)) {
        debugPrint('SOURCES: kwik mention -> ${m.group(0)}');
      }
      for (final m in RegExp(r'<button[^>]{0,300}>').allMatches(html).take(6)) {
        debugPrint('SOURCES: button -> ${m.group(0)}');
      }
      for (final m in RegExp(r'data-(?:src|resolution|audio)="[^"]{0,80}"')
          .allMatches(html)
          .take(6)) {
        debugPrint('SOURCES: attr -> ${m.group(0)}');
      }
      throw NoSourcesFound(url);
    }
    debugPrint('SOURCES: found ${sources.length} on $url');
    return sources;
  }

  /// Extracts kwik.si sources from a play page.
  ///
  /// Attribute order is not assumed and the markup is walked with a real HTML
  /// parser, because a positional regex breaks the moment the page is
  /// re-rendered. Falls back to scanning raw text so a layout change degrades
  /// to fewer sources rather than none.
  @visibleForTesting
  static List<StreamSource> parsePlayPage(String html) {
    if (html.isEmpty) return const [];
    final found = <String, StreamSource>{}; // keyed by url — dedupes strategies

    void add(String? url, String? res, String? audio, String? size) {
      if (url == null || !url.contains('kwik')) return;
      final quality = _normalizeQuality(res) ?? _qualityFromText(url) ?? '';
      found.putIfAbsent(
        url,
        () => StreamSource(
          kwikUrl: url,
          quality: quality.isEmpty ? 'unknown' : quality,
          audio: (audio == null || audio.isEmpty) ? 'jpn' : audio,
          fileSize: size ?? '',
        ),
      );
    }

    try {
      final doc = html_parser.parse(html);
      // Download anchors and the resolution menu both carry the same data-*
      // attributes; querying by attribute presence avoids depending on
      // container ids that change with the theme.
      for (final el in doc.querySelectorAll('a, button')) {
        final a = el.attributes;
        final url = a['data-src'] ?? a['href'];
        if (url == null || !url.contains('kwik')) continue;
        add(
          url,
          a['data-resolution'] ?? a['data-res'] ?? a['data-quality'],
          a['data-audio'] ?? a['data-lang'],
          a['data-filesize'] ?? a['data-size'],
        );
        // Link text is often "720p (250MB)" / "eng · 1080p" when attrs are absent.
        if (found[url]?.quality == 'unknown') {
          final text = el.text;
          final q = _qualityFromText(text);
          if (q != null) {
            found[url] = StreamSource(
              kwikUrl: url,
              quality: q,
              audio: _audioFromText(text) ?? found[url]!.audio,
              fileSize: found[url]!.fileSize,
            );
          }
        }
      }
    } catch (_) {
      // fall through to the raw scan
    }

    // Raw scan: catches sources built by inline JS, which the DOM walk misses.
    if (found.isEmpty) {
      for (final m in RegExp(r'https?://[^\s"\x27\\]*kwik\.[a-z]{2,6}/[ef]/[\w-]+')
          .allMatches(html)) {
        final url = m.group(0)!;
        // Look at a window of text after the link for a quality/audio hint.
        final tailEnd = (m.end + 240).clamp(0, html.length);
        final tail = html.substring(m.end, tailEnd);
        add(url, null, _audioFromText(tail), null);
        final q = _qualityFromText(tail);
        if (q != null && found[url]!.quality == 'unknown') {
          found[url] = StreamSource(
            kwikUrl: url,
            quality: q,
            audio: found[url]!.audio,
            fileSize: '',
          );
        }
      }
    }

    final list = found.values.toList();
    list.sort((a, b) {
      // Sub before dub, then highest quality first.
      final byAudio = (a.isDub ? 1 : 0) - (b.isDub ? 1 : 0);
      if (byAudio != 0) return byAudio;
      return _qualityRank(b.quality) - _qualityRank(a.quality);
    });
    return list;
  }

  static String? _normalizeQuality(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final digits = RegExp(r'(\d{3,4})').firstMatch(raw)?.group(1);
    return digits == null ? null : '${digits}p';
  }

  static String? _qualityFromText(String? text) {
    if (text == null) return null;
    final m = RegExp(r'\b(2160|1440|1080|720|480|360)\s*p?\b', caseSensitive: false)
        .firstMatch(text);
    return m == null ? null : '${m.group(1)}p';
  }

  static String? _audioFromText(String? text) {
    if (text == null) return null;
    final t = text.toLowerCase();
    if (t.contains('eng') || t.contains('dub')) return 'eng';
    if (t.contains('jpn') || t.contains('sub')) return 'jpn';
    return null;
  }

  /// Unparseable qualities sort last instead of throwing, which the old
  /// int.parse comparator did.
  static int _qualityRank(String q) =>
      int.tryParse(q.replaceAll(RegExp(r'[^0-9]'), '')) ?? -1;

  /// The airing feed returns episode releases, not anime records — the fields
  /// are anime_title / anime_session / snapshot, so it needs its own mapping.
  Future<List<Anime>> getRecent({int page = 1}) async {
    if (PreviewMode.enabled) return PreviewMode.catalogue;
    final r = await _getJson({'m': 'airing', 'page': '$page'});
    final data = r['data'] as List? ?? [];
    final seen = <String>{};
    final out = <Anime>[];
    for (final j in data) {
      final a = Anime.fromAiring(j as Map<String, dynamic>);
      if (a.session.isEmpty || !seen.add(a.session)) continue; // one card per show
      out.add(a);
    }
    return out;
  }
}
