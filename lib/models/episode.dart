class Episode {
  final String session;
  final int number;
  final String title;
  final String snapshot;
  final String duration;
  final String fansub;
  final String audio; // sub / dub
  final String createdAt;
  final String animeSession;

  const Episode({
    required this.session,
    required this.number,
    required this.title,
    required this.snapshot,
    required this.duration,
    required this.fansub,
    required this.audio,
    required this.createdAt,
    required this.animeSession,
  });

  factory Episode.fromJson(Map<String, dynamic> j, String animeSession) =>
      Episode(
        session: j['session'] ?? '',
        number: j['episode'] ?? 0,
        title: j['title2'] ?? '',
        snapshot: j['snapshot'] ?? '',
        duration: j['duration'] ?? '',
        fansub: j['fansub'] ?? '',
        audio: j['audio'] ?? 'sub',
        createdAt: j['created_at'] ?? '',
        animeSession: animeSession,
      );

  String get playUrl => 'https://animepahe.ru/play/$animeSession/$session';
  bool get isDub => audio.toLowerCase().contains('dub');
  String get displayTitle =>
      title.isNotEmpty ? 'EP $number — $title' : 'Episode $number';
}
