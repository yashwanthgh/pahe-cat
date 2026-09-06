import 'dart:math' as math;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/anime.dart';
import '../models/episode.dart';
import '../models/watch_progress.dart';
import 'animepahe_api.dart';
import 'watch_progress_db.dart';

/// Rebuilds anything showing progress whenever stored progress changes.
///
/// Watched rather than invalidated by hand: progress is written from the
/// player's teardown and from a route already replaced by the player, so
/// there is no live widget left to do the invalidating.
final progressRevisionProvider =
    StreamProvider<int>((ref) => WatchProgressDb.changes);

/// Shared so the player screen can invalidate it after an episode is watched
/// and the detail screen's checkmarks update without an app restart.
final watchProgressProvider =
    FutureProvider.family<WatchProgress?, String>((ref, animeSession) {
  ref.watch(progressRevisionProvider);
  return WatchProgressDb.get(animeSession);
});

final watchHistoryProvider = FutureProvider<List<WatchProgress>>((ref) {
  ref.watch(progressRevisionProvider);
  return WatchProgressDb.getAll();
});

/// A selectable span of episodes, e.g. "EP 1–120".
class EpisodeRange {
  final int index;
  final int firstPage;
  final int lastPage;
  final int firstEpisode;
  final int lastEpisode;

  const EpisodeRange({
    required this.index,
    required this.firstPage,
    required this.lastPage,
    required this.firstEpisode,
    required this.lastEpisode,
  });

  String get label => 'EP $firstEpisode–$lastEpisode';
}

class EpisodesState {
  final List<Episode> episodes;
  final int loadedPages;
  final int totalPages;
  final int perPage;
  final int total;
  final bool loading;
  final String? error;

  /// Which range is on screen. Null until the first page arrives.
  final EpisodeRange? selected;

  const EpisodesState({
    this.episodes = const [],
    this.loadedPages = 0,
    this.totalPages = 1,
    this.perPage = 30,
    this.total = 0,
    this.loading = false,
    this.error,
    this.selected,
  });

  bool get isInitialLoad => loading && episodes.isEmpty;

  /// True while more pages remain inside the selected range.
  bool get hasMore {
    final r = selected;
    if (r == null) return loadedPages < totalPages;
    return loadedPages < r.lastPage;
  }

  /// Roughly 100 episodes per range, rounded to whole API pages since pages
  /// are the only unit the API can actually be asked for.
  List<EpisodeRange> get ranges {
    if (totalPages <= 1 || perPage <= 0) return const [];
    final pagesPerChunk = math.max(1, (100 / perPage).ceil());
    final chunks = (totalPages / pagesPerChunk).ceil();
    if (chunks <= 1) return const [];
    return [
      for (var i = 0; i < chunks; i++)
        () {
          final firstPage = i * pagesPerChunk + 1;
          final lastPage = math.min((i + 1) * pagesPerChunk, totalPages);
          return EpisodeRange(
            index: i,
            firstPage: firstPage,
            lastPage: lastPage,
            firstEpisode: (firstPage - 1) * perPage + 1,
            lastEpisode: total > 0
                ? math.min(lastPage * perPage, total)
                : lastPage * perPage,
          );
        }(),
    ];
  }

  EpisodesState copyWith({
    List<Episode>? episodes,
    int? loadedPages,
    int? totalPages,
    int? perPage,
    int? total,
    bool? loading,
    String? error,
    EpisodeRange? selected,
  }) =>
      EpisodesState(
        episodes: episodes ?? this.episodes,
        loadedPages: loadedPages ?? this.loadedPages,
        totalPages: totalPages ?? this.totalPages,
        perPage: perPage ?? this.perPage,
        total: total ?? this.total,
        loading: loading ?? this.loading,
        error: error,
        selected: selected ?? this.selected,
      );
}

/// Loads episodes a page at a time, within a selected range.
///
/// Fetching every page up front made opening a long series fire ~40 requests
/// at once, which animepahe answered with 429. Ranges also make a
/// 1000-episode series navigable instead of an endless scroll.
class EpisodesNotifier extends StateNotifier<EpisodesState> {
  final String animeSession;

  EpisodesNotifier(this.animeSession) : super(const EpisodesState()) {
    loadMore();
  }

  Future<void> loadMore() async {
    if (state.loading || !state.hasMore) return;
    await _fetchPage(state.loadedPages + 1, append: true);
  }

  /// Jumps to a range, replacing what is on screen with its first page.
  Future<void> selectRange(EpisodeRange range) async {
    if (state.loading) return;
    state = state.copyWith(
      episodes: const [],
      loadedPages: range.firstPage - 1,
      selected: range,
    );
    await _fetchPage(range.firstPage, append: true);
  }

  Future<void> retry() => _fetchPage(state.loadedPages + 1, append: true);

  Future<void> _fetchPage(int page, {required bool append}) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final res = await AnimePaheApi().getEpisodes(animeSession, page: page);
      final merged = append
          ? ([...state.episodes, ...res.episodes]
            ..sort((a, b) => a.number.compareTo(b.number)))
          : res.episodes;
      state = state.copyWith(
        episodes: merged,
        loadedPages: page,
        totalPages: res.totalPages,
        perPage: res.perPage,
        total: res.total,
        loading: false,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }
}

final episodesControllerProvider = StateNotifierProvider.family<
    EpisodesNotifier, EpisodesState, String>(
  (ref, animeSession) => EpisodesNotifier(animeSession),
);

/// The home screen's feed of recently aired anime.
///
/// Paged rather than a one-shot fetch: collapsing the airing feed to one card
/// per show means a single page fills only a fraction of a desktop window, so
/// the first load takes several pages and scrolling to the bottom takes more.
class AiringState {
  final List<Anime> anime;
  final bool loading;
  final bool loadingMore;
  final bool hasMore;
  final Object? error;

  const AiringState({
    this.anime = const [],
    this.loading = true,
    this.loadingMore = false,
    this.hasMore = true,
    this.error,
  });

  AiringState copyWith({
    List<Anime>? anime,
    bool? loading,
    bool? loadingMore,
    bool? hasMore,
    Object? error,
    bool clearError = false,
  }) =>
      AiringState(
        anime: anime ?? this.anime,
        loading: loading ?? this.loading,
        loadingMore: loadingMore ?? this.loadingMore,
        hasMore: hasMore ?? this.hasMore,
        error: clearError ? null : (error ?? this.error),
      );
}

class AiringNotifier extends StateNotifier<AiringState> {
  AiringNotifier() : super(const AiringState()) {
    _loadFirst();
  }

  /// Enough to fill a large window on first paint without a visible gap.
  static const _firstBatch = 3;
  static const _nextBatch = 2;

  int _nextPage = 1;
  int _lastPage = 1;

  Future<void> _loadFirst() async {
    try {
      final r = await AnimePaheApi().getRecent(page: 1, pages: _firstBatch);
      _nextPage = 1 + _firstBatch;
      _lastPage = r.lastPage;
      state = AiringState(
        anime: r.anime,
        loading: false,
        hasMore: _nextPage <= _lastPage,
      );
    } catch (e) {
      state = AiringState(loading: false, hasMore: false, error: e);
    }
  }

  Future<void> loadMore() async {
    if (state.loadingMore || !state.hasMore || state.loading) return;
    state = state.copyWith(loadingMore: true, clearError: true);
    try {
      final r = await AnimePaheApi().getRecent(
        page: _nextPage,
        pages: _nextBatch,
        // Already-shown shows must not reappear further down the grid.
        exclude: state.anime.map((a) => a.session).toSet(),
      );
      _nextPage += _nextBatch;
      _lastPage = r.lastPage;
      state = state.copyWith(
        anime: [...state.anime, ...r.anime],
        loadingMore: false,
        hasMore: _nextPage <= _lastPage,
      );
    } catch (e) {
      state = state.copyWith(loadingMore: false, error: e);
    }
  }

  Future<void> retry() {
    if (state.anime.isEmpty) {
      state = const AiringState();
      return _loadFirst();
    }
    return loadMore();
  }
}

final airingProvider =
    StateNotifierProvider<AiringNotifier, AiringState>((_) => AiringNotifier());
