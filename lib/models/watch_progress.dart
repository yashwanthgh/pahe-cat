/// Where a viewer is up to in one series.
///
/// [lastEpisode] is the *furthest* episode reached, not the most recently
/// opened one. Storing "most recent" moved a viewer backwards the moment they
/// rewatched an earlier episode, which lost their place in the series.
/// [resumeEpisode] and [resumePosition] carry the actual place to continue
/// from, so re-opening a part-watched episode picks up where it stopped.
class WatchProgress {
  final String animeSession;
  final String animeTitle;
  final String animePoster;

  /// Furthest episode number reached.
  final int lastEpisode;
  final int totalEpisodes;

  /// The episode to offer on "Continue", and how far into it to start.
  final int resumeEpisode;

  /// 0-1 through [resumeEpisode].
  final double resumePosition;

  final DateTime updatedAt;

  const WatchProgress({
    required this.animeSession,
    required this.animeTitle,
    required this.animePoster,
    required this.lastEpisode,
    required this.totalEpisodes,
    required this.updatedAt,
    this.resumeEpisode = 0,
    this.resumePosition = 0,
  });

  double get progressFraction =>
      totalEpisodes > 0 ? lastEpisode / totalEpisodes : 0;

  String get progressLabel => '$lastEpisode / $totalEpisodes ep';

  /// An episode counts as finished near the end, because closing credits mean
  /// nobody watches to exactly 1.0.
  static const completedAt = 0.9;

  /// True when enough of the episode was watched to be worth showing a
  /// percentage. Merely opening an episode does not qualify.
  bool get hasPartialEpisode =>
      resumeEpisode > 0 && resumePosition > 0.02 && resumePosition < completedAt;

  /// The episode "Continue" should open.
  ///
  /// The episode last opened wins, even barely into it: jumping to episode 4
  /// and coming back should offer episode 4, not whatever was watched before.
  /// A finished episode moves on to the next one instead.
  int get continueEpisode {
    if (resumeEpisode <= 0) return lastEpisode + 1;
    if (resumePosition < completedAt) return resumeEpisode;
    return resumeEpisode + 1;
  }

  String get resumeLabel {
    if (hasPartialEpisode) {
      return 'EP $resumeEpisode · ${(resumePosition * 100).round()}%';
    }
    return 'EP $continueEpisode';
  }

  WatchProgress copyWith({
    int? lastEpisode,
    int? totalEpisodes,
    int? resumeEpisode,
    double? resumePosition,
    DateTime? updatedAt,
  }) =>
      WatchProgress(
        animeSession: animeSession,
        animeTitle: animeTitle,
        animePoster: animePoster,
        lastEpisode: lastEpisode ?? this.lastEpisode,
        totalEpisodes: totalEpisodes ?? this.totalEpisodes,
        resumeEpisode: resumeEpisode ?? this.resumeEpisode,
        resumePosition: resumePosition ?? this.resumePosition,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toMap() => {
        'anime_session': animeSession,
        'anime_title': animeTitle,
        'anime_poster': animePoster,
        'last_episode': lastEpisode,
        'total_episodes': totalEpisodes,
        'resume_episode': resumeEpisode,
        'resume_position': resumePosition,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  factory WatchProgress.fromMap(Map<String, dynamic> m) => WatchProgress(
        animeSession: m['anime_session'] as String,
        animeTitle: (m['anime_title'] ?? '') as String,
        animePoster: (m['anime_poster'] ?? '') as String,
        lastEpisode: (m['last_episode'] as int?) ?? 0,
        totalEpisodes: (m['total_episodes'] as int?) ?? 0,
        // Absent on rows written before these columns existed.
        resumeEpisode: (m['resume_episode'] as int?) ?? 0,
        resumePosition: (m['resume_position'] as num?)?.toDouble() ?? 0,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(m['updated_at'] as int),
      );
}

/// How far through one specific episode a viewer got.
///
/// Kept per episode so nothing in the middle of a series is lost: the episode
/// list can mark what has been watched, and any individual episode can be
/// resumed rather than only the latest one.
class EpisodeProgress {
  final String animeSession;
  final int episodeNumber;

  /// 0-1 through the episode.
  final double position;

  final DateTime updatedAt;

  const EpisodeProgress({
    required this.animeSession,
    required this.episodeNumber,
    required this.position,
    required this.updatedAt,
  });

  bool get isCompleted => position >= WatchProgress.completedAt;
  bool get isStarted => position > 0.02;

  Map<String, dynamic> toMap() => {
        'anime_session': animeSession,
        'episode_number': episodeNumber,
        'position': position,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  factory EpisodeProgress.fromMap(Map<String, dynamic> m) => EpisodeProgress(
        animeSession: m['anime_session'] as String,
        episodeNumber: (m['episode_number'] as int?) ?? 0,
        position: (m['position'] as num?)?.toDouble() ?? 0,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(m['updated_at'] as int),
      );
}
