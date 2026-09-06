class WatchProgress {
  final String animeSession;
  final String animeTitle;
  final String animePoster;
  final int lastEpisode;
  final int totalEpisodes;
  final DateTime updatedAt;

  const WatchProgress({
    required this.animeSession,
    required this.animeTitle,
    required this.animePoster,
    required this.lastEpisode,
    required this.totalEpisodes,
    required this.updatedAt,
  });

  double get progressFraction =>
      totalEpisodes > 0 ? lastEpisode / totalEpisodes : 0;

  String get progressLabel => '$lastEpisode / $totalEpisodes ep';

  WatchProgress copyWith({int? lastEpisode, DateTime? updatedAt}) =>
      WatchProgress(
        animeSession: animeSession,
        animeTitle: animeTitle,
        animePoster: animePoster,
        lastEpisode: lastEpisode ?? this.lastEpisode,
        totalEpisodes: totalEpisodes,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toMap() => {
        'anime_session': animeSession,
        'anime_title': animeTitle,
        'anime_poster': animePoster,
        'last_episode': lastEpisode,
        'total_episodes': totalEpisodes,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  factory WatchProgress.fromMap(Map<String, dynamic> m) => WatchProgress(
        animeSession: m['anime_session'],
        animeTitle: m['anime_title'],
        animePoster: m['anime_poster'],
        lastEpisode: m['last_episode'],
        totalEpisodes: m['total_episodes'],
        updatedAt:
            DateTime.fromMillisecondsSinceEpoch(m['updated_at']),
      );
}
