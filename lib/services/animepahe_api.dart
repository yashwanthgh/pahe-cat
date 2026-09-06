import 'package:dio/dio.dart';
import '../models/anime.dart';
import '../models/episode.dart';
import '../models/stream_source.dart';
import 'cf_session.dart';

class AnimePaheApi {
  static final AnimePaheApi _i = AnimePaheApi._();
  AnimePaheApi._();
  factory AnimePaheApi() => _i;

  static const _base = 'https://animepahe.ru';
  late final Dio _dio = Dio(BaseOptions(
    baseUrl: _base,
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
  ));

  Options get _opts => Options(headers: CfSession().dioHeaders);

  Future<List<Anime>> search(String query) async {
    final r = await _dio.get(
      '/api',
      queryParameters: {'m': 'search', 'q': query},
      options: _opts,
    );
    final data = r.data['data'] as List? ?? [];
    return data.map((j) => Anime.fromJson(j as Map<String, dynamic>)).toList();
  }

  Future<({List<Episode> episodes, int totalPages, int currentPage})>
      getEpisodes(String animeSession, {int page = 1}) async {
    final r = await _dio.get(
      '/api',
      queryParameters: {
        'm': 'release',
        'id': animeSession,
        'sort': 'episode_asc',
        'page': page,
      },
      options: _opts,
    );
    final data = r.data['data'] as List? ?? [];
    final episodes = data
        .map((j) => Episode.fromJson(j as Map<String, dynamic>, animeSession))
        .toList();
    return (
      episodes: episodes,
      totalPages: r.data['last_page'] ?? 1,
      currentPage: r.data['current_page'] ?? 1,
    );
  }

  /// Fetches the play page and extracts all kwik.si sources grouped by quality/audio.
  Future<List<StreamSource>> getSources(
      String animeSession, String episodeSession) async {
    final url = '$_base/play/$animeSession/$episodeSession';
    final r = await _dio.get(url, options: _opts);
    return _parsePlayPage(r.data as String);
  }

  List<StreamSource> _parsePlayPage(String html) {
    final sources = <StreamSource>[];
    // The play page embeds sources in a <div id="pickDownload"> or button data attrs
    // Pattern: data-src="https://kwik.si/e/<hash>" data-resolution="720" data-audio="jpn" data-filesize="..."
    final re = RegExp(
      r'data-src="(https://kwik\.si/e/[^"]+)"[^>]*?'
      r'data-resolution="(\d+)"[^>]*?'
      r'data-audio="([^"]+)"[^>]*?'
      r'(?:data-filesize="([^"]*)")?',
      dotAll: true,
    );
    for (final m in re.allMatches(html)) {
      sources.add(StreamSource(
        kwikUrl: m.group(1)!,
        quality: '${m.group(2)}p',
        audio: m.group(3)!,
        fileSize: m.group(4) ?? '',
      ));
    }
    // Fallback: look for button elements
    if (sources.isEmpty) {
      final re2 = RegExp(
        r'"source":"(https://kwik\.si/e/[^"]+)".*?"resolution":(\d+).*?"audio":"([^"]+)"',
        dotAll: true,
      );
      for (final m in re2.allMatches(html)) {
        sources.add(StreamSource(
          kwikUrl: m.group(1)!,
          quality: '${m.group(2)}p',
          audio: m.group(3)!,
          fileSize: '',
        ));
      }
    }
    // Sort: sub before dub, highest quality first
    sources.sort((a, b) {
      final audioCompare = (a.isDub ? 1 : 0) - (b.isDub ? 1 : 0);
      if (audioCompare != 0) return audioCompare;
      return int.parse(b.quality.replaceAll('p', '')) -
          int.parse(a.quality.replaceAll('p', ''));
    });
    return sources;
  }

  Future<List<Anime>> getRecent({int page = 1}) async {
    final r = await _dio.get(
      '/api',
      queryParameters: {'m': 'airing', 'page': page},
      options: _opts,
    );
    final data = r.data['data'] as List? ?? [];
    return data.map((j) => Anime.fromJson(j as Map<String, dynamic>)).toList();
  }
}
