import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../models/anime.dart';
import '../models/episode.dart';
import '../models/watch_progress.dart';
import '../services/animepahe_api.dart';
import '../services/watch_progress_db.dart';
import '../theme.dart';
import 'episode_player_screen.dart';

final _episodesProvider = FutureProvider.family<List<Episode>, String>(
    (ref, session) => AnimePaheApi()
        .getEpisodes(session)
        .then((r) => r.episodes));

final _progressProvider =
    FutureProvider.family<WatchProgress?, String>((ref, session) async {
  return WatchProgressDb.get(session);
});

class AnimeDetailScreen extends ConsumerWidget {
  final Anime anime;
  const AnimeDetailScreen({super.key, required this.anime});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final episodes = ref.watch(_episodesProvider(anime.session));
    final progress = ref.watch(_progressProvider(anime.session));

    return Scaffold(
      backgroundColor: PaheColors.bg,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 280,
            pinned: true,
            backgroundColor: PaheColors.surface,
            flexibleSpace: FlexibleSpaceBar(
              background: _HeroBanner(anime: anime),
            ),
            leading: IconButton(
              icon: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 18),
              ),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    anime.title,
                    style: const TextStyle(
                      color: PaheColors.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _InfoRow(anime: anime),
                  // Continue watching button
                  progress.when(
                    loading: () => const SizedBox.shrink(),
                    error: (_, __) => const SizedBox.shrink(),
                    data: (p) => p != null
                        ? _ContinueButton(anime: anime, progress: p)
                        : const SizedBox.shrink(),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'EPISODES',
                    style: TextStyle(
                      color: PaheColors.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
          episodes.when(
            loading: () => const SliverFillRemaining(
              child: Center(
                child: CircularProgressIndicator(color: PaheColors.purple),
              ),
            ),
            error: (e, _) => SliverFillRemaining(
              child: Center(
                child: Text('Error: $e',
                    style: const TextStyle(color: PaheColors.textMuted)),
              ),
            ),
            data: (list) => SliverList(
              delegate: SliverChildBuilderDelegate(
                (ctx, i) => _EpisodeTile(
                  episode: list[i],
                  anime: anime,
                  isWatched: progress.valueOrNull != null &&
                      list[i].number <= (progress.valueOrNull?.lastEpisode ?? 0),
                ).animate().slideX(
                      begin: 0.05,
                      delay: Duration(milliseconds: i * 20),
                      duration: const Duration(milliseconds: 200),
                    ),
                childCount: list.length,
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}

class _HeroBanner extends StatelessWidget {
  final Anime anime;
  const _HeroBanner({required this.anime});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        CachedNetworkImage(imageUrl: anime.poster, fit: BoxFit.cover),
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(color: Colors.black.withOpacity(0.5)),
        ),
        Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: CachedNetworkImage(
              imageUrl: anime.poster,
              height: 220,
              fit: BoxFit.cover,
            ),
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  final Anime anime;
  const _InfoRow({required this.anime});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        _Chip(text: anime.type, icon: Icons.tv_rounded),
        _Chip(text: '${anime.episodes} eps'),
        if (anime.score > 0)
          _Chip(text: '★ ${anime.score.toStringAsFixed(1)}', color: PaheColors.amber),
        _Chip(text: anime.status,
            color: anime.status == 'Ongoing' ? PaheColors.green : PaheColors.textMuted),
        if (anime.season.isNotEmpty) _Chip(text: anime.season),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;

  const _Chip({required this.text, this.color = PaheColors.textSecondary, this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
          ],
          Text(text, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _ContinueButton extends StatelessWidget {
  final Anime anime;
  final WatchProgress progress;

  const _ContinueButton({required this.anime, required this.progress});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            // Navigate to next episode
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              gradient: PaheColors.gradient,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 20),
                const SizedBox(width: 8),
                Text(
                  'Continue — EP ${progress.lastEpisode + 1}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                const Spacer(),
                Text(
                  progress.progressLabel,
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EpisodeTile extends ConsumerWidget {
  final Episode episode;
  final Anime anime;
  final bool isWatched;

  const _EpisodeTile({
    required this.episode,
    required this.anime,
    required this.isWatched,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
      decoration: BoxDecoration(
        color: PaheColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PaheColors.border),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isWatched
                ? PaheColors.purple.withOpacity(0.2)
                : PaheColors.border,
          ),
          child: Center(
            child: isWatched
                ? const Icon(Icons.check_rounded, color: PaheColors.purple, size: 18)
                : Text(
                    '${episode.number}',
                    style: const TextStyle(
                      color: PaheColors.textSecondary,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
          ),
        ),
        title: Text(
          episode.displayTitle,
          style: TextStyle(
            color: isWatched ? PaheColors.textMuted : PaheColors.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          episode.isDub ? 'DUB' : 'SUB',
          style: TextStyle(
            color: episode.isDub ? PaheColors.pink : PaheColors.cyan,
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.play_circle_outline_rounded,
              color: PaheColors.purple, size: 28),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => EpisodePlayerScreen(
                anime: anime,
                episode: episode,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
