import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shimmer/shimmer.dart';
import '../models/anime.dart';
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
final _recentProvider = FutureProvider<List<Anime>>((ref) async {
  return AnimePaheApi().getRecent();
});
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
              child: query.isEmpty ? _RecentGrid() : _SearchResults(query: query),
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

class _RecentGrid extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = ref.watch(_recentProvider);
    return recent.when(
      loading: () => _ShimmerGrid(),
      error: (e, _) => _ErrorState(message: e.toString()),
      data: (list) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Text(
              'Recently Aired',
              style: TextStyle(
                color: PaheColors.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (ctx, box) => GridView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              gridDelegate: _posterGridFor(box.maxWidth - 24),
              itemCount: list.length,
              itemBuilder: (ctx, i) => AnimeCard(
                anime: list[i],
                onTap: () => _open(context, list[i]),
              ),
            ),
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
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, box) => GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      gridDelegate: _posterGridFor(box.maxWidth - 24),
      itemCount: 9,
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
