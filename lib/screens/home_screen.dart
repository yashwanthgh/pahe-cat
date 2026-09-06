import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shimmer/shimmer.dart';
import '../models/anime.dart';
import '../models/watch_progress.dart';
import '../services/providers.dart';
import '../services/animepahe_api.dart';
import '../theme.dart';
import '../widgets/anime_card.dart';
import 'anime_detail_screen.dart';

/// Sizes tiles from the real column width rather than a fixed aspect ratio.
///
/// A constant ratio cannot hold a poster's natural 2:3 shape once the column
/// count changes with screen width — narrow phone columns came out visibly
/// stretched. Here the height is derived: poster at 2:3, plus a fixed strip
/// for the title.
const _posterTarget = 168.0;
const _posterSpacing = 10.0;
const _posterTextStrip = 54.0;

SliverGridDelegate _posterGridFor(double width) {
  final columns = (width / _posterTarget).ceil().clamp(2, 10);
  final tileWidth =
      (width - _posterSpacing * (columns - 1)) / columns;
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: columns,
    crossAxisSpacing: _posterSpacing,
    mainAxisSpacing: _posterSpacing,
    mainAxisExtent: tileWidth * 1.5 + _posterTextStrip,
  );
}

final _searchQueryProvider = StateProvider<String>((ref) => '');
final _searchResultsProvider =
    FutureProvider.family<List<Anime>, String>((ref, query) async {
  if (query.isEmpty) return [];
  return AnimePaheApi().search(query);
});

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _ctrl = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  /// Without this every keystroke fired a search request, which wastes the
  /// Cloudflare clearance we just spent a handshake on.
  void _onQueryChanged(String value) {
    _debounce?.cancel();
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      ref.read(_searchQueryProvider.notifier).state = '';
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) ref.read(_searchQueryProvider.notifier).state = trimmed;
    });
  }

  void _submitNow(String value) {
    _debounce?.cancel();
    ref.read(_searchQueryProvider.notifier).state = value.trim();
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(_searchQueryProvider);
    return Scaffold(
      backgroundColor: PaheColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Header(),
            _SearchBar(
              ctrl: _ctrl,
              onChanged: _onQueryChanged,
              onSubmitted: _submitNow,
            ),
            Expanded(
              child: query.isEmpty
                  ? const _RecentGrid()
                  : _SearchResults(query: query),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
      child: Row(
        children: [
          ShaderMask(
            shaderCallback: (b) => PaheColors.gradient.createShader(b),
            child: const Text(
              'Pahe Cat',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w900,
                color: Colors.white,
                letterSpacing: -0.5,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              gradient: PaheColors.gradient,
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Text(
              'BETA',
              style: TextStyle(
                color: Colors.white,
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchBar extends ConsumerWidget {
  final TextEditingController ctrl;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  const _SearchBar({
    required this.ctrl,
    required this.onChanged,
    required this.onSubmitted,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: TextField(
        controller: ctrl,
        style: const TextStyle(color: PaheColors.textPrimary),
        decoration: InputDecoration(
          hintText: 'Search anime…',
          prefixIcon: const Icon(Icons.search_rounded, color: PaheColors.textMuted),
          suffixIcon: ctrl.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.close_rounded, color: PaheColors.textMuted),
                  onPressed: () {
                    ctrl.clear();
                    ref.read(_searchQueryProvider.notifier).state = '';
                  },
                )
              : null,
        ),
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        textInputAction: TextInputAction.search,
      ),
    );
  }
}

/// Picks up where the viewer left off.
///
/// animepahe has no accounts, so this local record is the whole reason the app
/// exists. It sits at the top of the home screen because it is the thing most
/// often wanted on opening the app — previously it lived only on the Library
/// tab and on each series' own page, which made it easy to miss.
class _ContinueWatchingRow extends ConsumerWidget {
  const _ContinueWatchingRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(watchHistoryProvider);
    return history.maybeWhen(
      orElse: () => const SizedBox.shrink(),
      data: (list) {
        final unfinished = list
            .where((p) => p.totalEpisodes == 0 || p.lastEpisode < p.totalEpisodes)
            .take(12)
            .toList();
        if (unfinished.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 10),
              child: Text(
                'Continue watching',
                style: TextStyle(
                  color: PaheColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            SizedBox(
              height: 96,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: unfinished.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (_, i) => _ContinueCard(progress: unfinished[i]),
              ),
            ),
            const SizedBox(height: 6),
          ],
        );
      },
    );
  }
}

class _ContinueCard extends StatelessWidget {
  final WatchProgress progress;
  const _ContinueCard({required this.progress});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 230,
      child: Material(
        color: PaheColors.card,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          // Opens the series page, where the episode list and the resume point
          // both live.
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => AnimeDetailScreen(
                anime: Anime.fromHistory(
                  session: progress.animeSession,
                  title: progress.animeTitle,
                  poster: progress.animePoster,
                ),
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  progress.animeTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: PaheColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (progress.hasPartialEpisode)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: progress.resumePosition,
                            minHeight: 3,
                            backgroundColor: PaheColors.cardHover,
                            valueColor: const AlwaysStoppedAnimation<Color>(
                                PaheColors.accent),
                          ),
                        ),
                      ),
                    Row(
                      children: [
                        const Icon(Icons.play_circle_fill_rounded,
                            color: PaheColors.accent, size: 16),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            progress.resumeLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: PaheColors.textSecondary,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          progress.lastSeenLabel,
                          style: const TextStyle(
                              color: PaheColors.textMuted, fontSize: 10),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The recently-aired grid, paged.
///
/// Loads more as it nears the bottom instead of ending in dead space: the
/// airing feed collapses to one card per show, so a single page left most of
/// a desktop window empty.
class _RecentGrid extends ConsumerStatefulWidget {
  const _RecentGrid();

  @override
  ConsumerState<_RecentGrid> createState() => _RecentGridState();
}

class _RecentGridState extends ConsumerState<_RecentGrid> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scroll.removeListener(_maybeLoadMore);
    _scroll.dispose();
    super.dispose();
  }

  /// Fetches the next pages before the bottom is actually reached, so
  /// scrolling does not stop dead while waiting.
  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    final remaining = _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (remaining < 900) ref.read(airingProvider.notifier).loadMore();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(airingProvider);

    if (state.loading) return const _ShimmerGrid();
    if (state.anime.isEmpty) {
      return _ErrorState(
        message: state.error?.toString() ?? 'Nothing to show yet.',
      );
    }

    return LayoutBuilder(
      builder: (ctx, box) => CustomScrollView(
        controller: _scroll,
        slivers: [
          const SliverToBoxAdapter(child: _ContinueWatchingRow()),
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Text(
                'Recently aired',
                style: TextStyle(
                  color: PaheColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverGrid(
              gridDelegate: _posterGridFor(box.maxWidth - 24),
              delegate: SliverChildBuilderDelegate(
                (ctx, i) => AnimeCard(
                  anime: state.anime[i],
                  onTap: () => _open(context, state.anime[i]),
                ),
                childCount: state.anime.length,
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: _GridFooter(
              state: state,
              onRetry: () => ref.read(airingProvider.notifier).retry(),
            ),
          ),
        ],
      ),
    );
  }

  void _open(BuildContext ctx, Anime a) {
    Navigator.push(ctx, MaterialPageRoute(builder: (_) => AnimeDetailScreen(anime: a)));
  }
}

/// Says what the bottom of the grid is doing, rather than just stopping.
class _GridFooter extends StatelessWidget {
  final AiringState state;
  final VoidCallback onRetry;

  const _GridFooter({required this.state, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    if (state.error != null) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: Column(
            children: [
              Text(
                // 429 is animepahe rate-limiting a burst, not a real failure,
                // so it is worth saying so instead of showing a raw error.
                state.error.toString().contains('429')
                    ? 'animepahe asked us to slow down.'
                    : 'Could not load more right now.',
                style: const TextStyle(
                    color: PaheColors.textMuted, fontSize: 12),
              ),
              const SizedBox(height: 8),
              TextButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ),
        ),
      );
    }
    if (state.loadingMore) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: PaheColors.accent),
          ),
        ),
      );
    }
    if (!state.hasMore) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(
          child: Text(
            'That is everything airing right now',
            style: TextStyle(color: PaheColors.textMuted, fontSize: 11),
          ),
        ),
      );
    }
    return const SizedBox(height: 24);
  }
}

class _SearchResults extends ConsumerWidget {
  final String query;
  const _SearchResults({required this.query});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = ref.watch(_searchResultsProvider(query));
    return results.when(
      loading: () => _ShimmerGrid(),
      error: (e, _) => _ErrorState(message: e.toString()),
      data: (list) {
        if (list.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.search_off_rounded, size: 48, color: PaheColors.textMuted),
                const SizedBox(height: 12),
                Text('No results for "$query"',
                    style: const TextStyle(color: PaheColors.textMuted)),
              ],
            ),
          );
        }
        return LayoutBuilder(
          builder: (ctx, box) => GridView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          gridDelegate: _posterGridFor(box.maxWidth - 24),
          itemCount: list.length,
          itemBuilder: (ctx, i) => AnimeCard(
            anime: list[i],
            onTap: () => Navigator.push(
                ctx, MaterialPageRoute(builder: (_) => AnimeDetailScreen(anime: list[i]))),
          ),
        ),
        );
      },
    );
  }
}

class _ShimmerGrid extends StatelessWidget {
  const _ShimmerGrid();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, box) => GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      gridDelegate: _posterGridFor(box.maxWidth - 24),
      itemCount: 12,
      itemBuilder: (_, __) => Shimmer.fromColors(
        baseColor: PaheColors.card,
        highlightColor: PaheColors.cardHover,
        child: Container(
          decoration: BoxDecoration(
            color: PaheColors.card,
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  const _ErrorState({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off_rounded, size: 48, color: PaheColors.textMuted),
            const SizedBox(height: 12),
            Text(
              'Could not load anime',
              style: const TextStyle(color: PaheColors.textPrimary, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(message, style: const TextStyle(color: PaheColors.textMuted, fontSize: 12),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
