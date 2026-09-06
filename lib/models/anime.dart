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
        poster: j['poster'] ?? '',
        type: j['type'] ?? 'TV',
        episodes: j['episodes'] ?? 0,
        status: j['status'] ?? '',
        season: j['season'] ?? '',
        year: j['year'] ?? 0,
        score: (j['score'] as num?)?.toDouble() ?? 0.0,
        slug: j['slug'] ?? '',
      );

  String get pageUrl => 'https://animepahe.ru/anime/$slug';
}
