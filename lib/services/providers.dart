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

  /// How many episodes the selected range is expected to hold, so filling it
  /// can be reported as progress rather than a bare spinner.
  int get expectedInRange {
    final r = selected;
    if (r == null) return total;
    return r.lastEpisode - r.firstEpisode + 1;
  }

  /// True once the selected range holds everything it should.
  bool get rangeComplete =>
      !hasMore && visibleEpisodes.length >= expectedInRange;

  /// Download chunk size. A whole page at once is too much to queue in one
  /// action, so a page is offered in fixed blocks.
  static const chunkSize = 25;

  /// The loaded episodes split into blocks of [chunkSize]. A 120-episode page
  /// gives five blocks, a 50-episode one gives two — the block size is fixed
  /// and the count follows from how much the page holds.
  List<List<Episode>> get downloadChunks {
    final sorted = [...visibleEpisodes]
      ..sort((a, b) => a.number.compareTo(b.number));
    return [
      for (var i = 0; i < sorted.length; i += chunkSize)
        sorted.sublist(i, math.min(i + chunkSize, sorted.length)),
    ];
  }

  /// Episodes per selectable page.
  ///
  /// Fifty rather than a hundred: a hundred needs four API pages of the
  /// 30-per-page feed, and fetching four in a row was answered with 429 part
  /// of the way through, leaving the page half-filled. Two pages fill
  /// reliably, and fifty is still a comfortable jump for a long series.
  static const pageSize = 50;

  /// Exactly [pageSize] episodes per range — 1-100, 101-200, and so on.
  ///
  /// Ranges used to be built by rounding up to whole API pages, which gave
  /// spans of 120 with a 30-per-page feed and a dropdown reading "EP 1-120".
  /// The boundaries are set in episode numbers now and the API pages needed
  /// are derived from them, so the label says what it means. The last range is
  /// short rather than overshooting the series.
  List<EpisodeRange> get ranges {
    if (perPage <= 0) return const [];
    final count = total > 0 ? total : episodes.length;
    if (count <= pageSize) return const [];
    final chunks = (count / pageSize).ceil();
    return [
      for (var i = 0; i < chunks; i++)
        () {
          final firstEpisode = i * pageSize + 1;
          final lastEpisode = math.min((i + 1) * pageSize, count);
          return EpisodeRange(
            index: i,
            // Which API pages hold those episode numbers.
            firstPage: ((firstEpisode - 1) ~/ perPage) + 1,
            lastPage: ((lastEpisode - 1) ~/ perPage) + 1,
            firstEpisode: firstEpisode,
            lastEpisode: lastEpisode,
          );
        }(),
    ];
  }

  /// The episodes to show: those inside the selected range.
  ///
  /// An API page can straddle a range boundary — with 30 per page, episodes
  /// 91-120 arrive together — so the tail is held back rather than shown under
  /// a heading that excludes it.
  List<Episode> get visibleEpisodes {
    final r = selected;
    if (r == null) return episodes;
    return episodes
        .where((e) => e.number >= r.firstEpisode && e.number <= r.lastEpisode)
        .toList();
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
    _fill();
  }

  /// Loads every remaining page of the selected range.
  ///
  /// The page is filled in one go rather than a page at a time behind a "load
  /// more" button: the range is labelled with the span it covers, so showing
  /// only the first 30 of it made the label untrue and left the reader
  /// clicking to reach episode 40. Pages are still fetched one at a time with
  /// a gap, because a burst is answered with 429.
  Future<void> _fill() async {
    while (state.hasMore && state.error == null) {
      final next = state.loadedPages + 1;
      await _fetchPage(next, append: true);
      if (state.error != null) break;
      if (state.hasMore) {
        await Future.delayed(const Duration(milliseconds: 250));
      }
    }
  }

  /// Kept for callers that ask for one more page explicitly.
  Future<void> loadMore() async {
    if (state.loading || !state.hasMore) return;
    await _fill();
  }

  /// Jumps to a range, replacing what is on screen and filling it.
  Future<void> selectRange(EpisodeRange range) async {
    if (state.loading) return;
    state = state.copyWith(
      episodes: const [],
      loadedPages: range.firstPage - 1,
      selected: range,
    );
    await _fill();
  }

  Future<void> retry() async {
    state = state.copyWith(error: null);
    await _fill();
  }

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

      // Adopt the range this page belongs to, if none was chosen yet.
      //
      // hasMore only caps at a range boundary once a range is selected, and
      // nothing selects one on the first load — so scrolling a long series
      // walked every page of it and the dropdown had nothing left to do. The
      // page count is known only after this first response, which is why this
      // happens here rather than in the constructor.
      if (state.selected == null) {
        final ranges = state.ranges;
        for (final r in ranges) {
          if (page >= r.firstPage && page <= r.lastPage) {
            state = state.copyWith(selected: r);
            break;
          }
        }
      }
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

/// Per-episode watch positions for one series, keyed by episode number.
///
/// Fetched as one map rather than a query per row, so an episode grid showing
/// a hundred cells does not issue a hundred reads.
final episodeProgressProvider =
    FutureProvider.family<Map<int, EpisodeProgress>, String>(
        (ref, animeSession) {
  ref.watch(progressRevisionProvider);
  return WatchProgressDb.getEpisodes(animeSession);
});
