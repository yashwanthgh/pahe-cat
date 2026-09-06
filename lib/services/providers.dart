import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/episode.dart';
import '../models/watch_progress.dart';
import 'animepahe_api.dart';
import 'watch_progress_db.dart';

/// Shared so the player screen can invalidate it after an episode is watched
/// and the detail screen's checkmarks update without an app restart.
final watchProgressProvider =
    FutureProvider.family<WatchProgress?, String>((ref, animeSession) {
  return WatchProgressDb.get(animeSession);
});

final watchHistoryProvider = FutureProvider<List<WatchProgress>>((ref) {
  return WatchProgressDb.getAll();
});

/// Every episode, not just the first page — long-running series span many.
final episodesProvider =
    FutureProvider.family<List<Episode>, String>((ref, animeSession) {
  return AnimePaheApi().getAllEpisodes(animeSession);
});
