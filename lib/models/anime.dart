import '../services/domain_resolver.dart';
class Anime {
  final String session;
  final String title;
  final String poster;
  final String type; // TV, Movie, OVA, ONA
  final int episodes;
  final String status; // Ongoing, Completed
  final String season;
  final int year;
  final double score;
  final String slug;

  const Anime({
    required this.session,
    required this.title,
    required this.poster,
    required this.type,
    required this.episodes,
    required this.status,
    required this.season,
    required this.year,
    required this.score,
    required this.slug,
  });

  factory Anime.fromJson(Map<String, dynamic> j) => Anime(
        session: j['session'] ?? '',
        title: j['title'] ?? '',
        poster: DomainResolver.rewriteAsset(j['poster'] ?? ''),
        type: j['type'] ?? 'TV',
        episodes: j['episodes'] ?? 0,
        status: j['status'] ?? '',
        season: j['season'] ?? '',
        year: j['year'] ?? 0,
        score: (j['score'] as num?)?.toDouble() ?? 0.0,
        slug: j['slug'] ?? '',
      );

  /// Only the facts we actually have. The airing feed carries neither an
  /// episode total nor a year, and "0 ep · 0" is worse than showing nothing.
  String get subtitle => [
        if (episodes > 0) '$episodes ep',
        if (year > 0) '$year',
      ].join(' · ');

  /// The `m=airing` feed returns episode releases rather than anime records,
  /// so the anime lives under anime_* keys and the only image is the episode
  /// snapshot. Mapping it with [Anime.fromJson] yields blank cards.
  factory Anime.fromAiring(Map<String, dynamic> j) => Anime(
        session: j['anime_session'] ?? '',
        title: j['anime_title'] ?? '',
        poster: DomainResolver.rewriteAsset(
            j['poster'] ?? j['snapshot'] ?? ''),
        type: j['type'] ?? 'TV',
        // The feed carries the latest episode number, not a series total.
        episodes: 0,
        status: 'Ongoing',
        season: '',
        year: 0,
        score: 0,
        slug: j['anime_slug'] ?? '',
      );
}
