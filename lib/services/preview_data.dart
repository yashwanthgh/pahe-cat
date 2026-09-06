import 'package:flutter/foundation.dart' show kIsWeb;
import '../models/anime.dart';
import '../models/episode.dart';
import '../models/stream_source.dart';

/// Design-preview mode.
///
/// The web build exists only to look at the UI on a laptop or a phone-sized
/// window. It cannot talk to animepahe: the browser blocks the cross-origin
/// calls, and clearing Cloudflare needs a native WebView. So on web the API
/// serves the fixtures below instead of stalling forever on the splash.
///
/// Native builds are untouched — [enabled] is false there.
class PreviewMode {
  static bool get enabled => kIsWeb;

  static const _posters = [
    'https://placehold.co/300x420/1a1a2e/9b59ff?text=Anime+1',
    'https://placehold.co/300x420/16213e/22d3ee?text=Anime+2',
    'https://placehold.co/300x420/1f1235/ff6b9d?text=Anime+3',
    'https://placehold.co/300x420/102a43/4ade80?text=Anime+4',
    'https://placehold.co/300x420/2a1a3e/ffb347?text=Anime+5',
    'https://placehold.co/300x420/1a2e2a/60a5fa?text=Anime+6',
  ];

  static final List<Anime> catalogue = [
    _anime('Frieren: Beyond Journeys End', 28, 8.9, 'TV', 'Fall', 2023, 0),
    _anime('One Piece', 1122, 8.7, 'TV', 'Fall', 1999, 1),
    _anime('Naruto Shippuden', 500, 8.2, 'TV', 'Winter', 2007, 2),
    _anime('Spirited Away', 1, 8.8, 'Movie', 'Summer', 2001, 3),
    _anime('Vinland Saga', 24, 8.7, 'TV', 'Winter', 2019, 4),
    _anime('Mushishi', 26, 8.6, 'TV', 'Fall', 2005, 5),
  ];

  static Anime _anime(String title, int eps, double score, String type,
          String season, int year, int posterIndex) =>
      Anime(
        session: 'preview-${title.hashCode}',
        title: title,
        poster: _posters[posterIndex % _posters.length],
        type: type,
        episodes: eps,
        status: eps > 100 ? 'Ongoing' : 'Completed',
        season: season,
        year: year,
        score: score,
        slug: title.toLowerCase().replaceAll(' ', '-'),
      );

  static List<Anime> search(String query) {
    final q = query.toLowerCase();
    return catalogue.where((a) => a.title.toLowerCase().contains(q)).toList();
  }

  /// Enough episodes to exercise the long-list and padding cases.
  static List<Episode> episodes(String animeSession) {
    final anime = catalogue.firstWhere(
      (a) => a.session == animeSession,
      orElse: () => catalogue.first,
    );
    final count = anime.episodes.clamp(1, 60);
    return [
      for (var i = 1; i <= count; i++)
        Episode(
          session: 'preview-ep-$i',
          number: i,
          title: i % 4 == 0 ? '' : 'Episode Title $i',
          snapshot: '',
          duration: '24:00',
          fansub: 'PreviewSub',
          audio: i % 5 == 0 ? 'eng' : 'jpn',
          createdAt: '2024-01-01',
          animeSession: animeSession,
        ),
    ];
  }

  /// Both audio tracks and several qualities, so the picker has real choices.
  static const List<StreamSource> sources = [
    StreamSource(quality: '1080p', kwikUrl: 'preview://1080-sub', audio: 'jpn', fileSize: '1.3 GB'),
    StreamSource(quality: '720p', kwikUrl: 'preview://720-sub', audio: 'jpn', fileSize: '620 MB'),
    StreamSource(quality: '360p', kwikUrl: 'preview://360-sub', audio: 'jpn', fileSize: '180 MB'),
    StreamSource(quality: '1080p', kwikUrl: 'preview://1080-dub', audio: 'eng', fileSize: '1.4 GB'),
    StreamSource(quality: '720p', kwikUrl: 'preview://720-dub', audio: 'eng', fileSize: '650 MB'),
  ];
}
