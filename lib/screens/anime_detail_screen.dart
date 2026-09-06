import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../widgets/cf_image.dart';
import '../models/anime.dart';
import '../models/episode.dart';
import '../models/watch_progress.dart';
import '../services/providers.dart';
import '../theme.dart';
import 'episode_player_screen.dart';
import 'bulk_download_sheet.dart';
import 'resume_flow.dart';

/// A series page that adapts to the window it is given.
///
/// On a laptop the single column left most of the width empty while the
/// episode list ran off the bottom, and the poster was shown small inside a
/// blurred banner. Wide windows now put a large poster and the series details
/// in a fixed left pane and lay the episodes out as a grid in the space that
/// was going to waste. Narrow windows keep the stacked layout, which is right
/// for a phone.
class AnimeDetailScreen extends ConsumerWidget {
  final Anime anime;
  const AnimeDetailScreen({super.key, required this.anime});

  /// Below this there is not enough width for a poster pane and a useful grid
  /// beside it, so the layout stacks instead.
  static const _wideBreakpoint = 820.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, box) => box.maxWidth >= _wideBreakpoint
          ? _WideLayout(anime: anime, width: box.maxWidth)
          : _NarrowLayout(anime: anime),
    );
  }
}

/// Shared pieces, so the two layouts cannot drift apart in behaviour.
class _DetailParts {
  final Anime anime;
  final WidgetRef ref;
  final BuildContext context;

  _DetailParts(this.anime, this.ref, this.context);

  EpisodesState get episodes =>
      ref.watch(episodesControllerProvider(anime.session));
  WatchProgress? get progress =>
      ref.watch(watchProgressProvider(anime.session)).valueOrNull;

  EpisodesNotifier get notifier =>
      ref.read(episodesControllerProvider(anime.session).notifier);

  Widget get continueButton => _ContinueButton(
        anime: anime,
        progress: progress,
        state: episodes,
        onJumpToRange: notifier.selectRange,
      );

  Widget episodesHeader({required bool showLabel}) {
    final state = episodes;
    return Row(
      children: [
        if (showLabel)
          const Text(
            'EPISODES',
            style: TextStyle(
              color: PaheColors.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
            ),
          ),
        const Spacer(),
        if (state.episodes.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.download_rounded,
                color: PaheColors.accent, size: 20),
            tooltip: 'Download several episodes',
            onPressed: () => BulkDownloadSheet.show(
              context,
              anime: anime,
              episodes: state.episodes,
              totalEpisodes:
                  state.total > 0 ? state.total : anime.episodes,
            ),
          ),
        if (state.ranges.isNotEmpty)
          _RangePicker(
            ranges: state.ranges,
            selected: state.selected ?? state.ranges.first,
            onSelected: notifier.selectRange,
          ),
      ],
    );
  }

  bool isWatched(Episode e) => e.number <= (progress?.lastEpisode ?? 0);

  Widget get loadMore => episodes.hasMore && !episodes.isInitialLoad
      ? _LoadMore(
          loading: episodes.loading,
          error: episodes.error,
          loaded: episodes.episodes.length,
          onLoad: notifier.loadMore,
        )
      : const SizedBox.shrink();

  Widget get errorState => _EpisodesError(
        message: episodes.error ?? 'Could not load episodes.',
        onRetry: notifier.retry,
      );
}

/// Phone-shaped: banner, details, then a vertical list.
class _NarrowLayout extends ConsumerWidget {
  final Anime anime;
  const _NarrowLayout({required this.anime});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parts = _DetailParts(anime, ref, context);
    final episodes = parts.episodes;

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
            leading: const _BackButton(),
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
                  parts.continueButton,
                  const SizedBox(height: 20),
                  parts.episodesHeader(showLabel: true),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
          if (episodes.isInitialLoad)
            const SliverFillRemaining(
              child: Center(
                child: CircularProgressIndicator(color: PaheColors.accent),
              ),
            )
          else if (episodes.episodes.isEmpty && episodes.error != null)
            SliverFillRemaining(child: parts.errorState)
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (ctx, i) => _EpisodeTile(
                  episode: episodes.episodes[i],
                  anime: anime,
                  isWatched: parts.isWatched(episodes.episodes[i]),
                  siblings: episodes.episodes,
                ),
                childCount: episodes.episodes.length,
              ),
            ),
          SliverToBoxAdapter(child: parts.loadMore),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}

/// Laptop-shaped: a poster pane on the left, an episode grid on the right.
class _WideLayout extends ConsumerWidget {
  final Anime anime;
  final double width;

  const _WideLayout({required this.anime, required this.width});

  /// Wide enough for a readable poster, capped so an ultrawide window does not
  /// hand the left pane half the screen.
  double get _paneWidth => (width * 0.28).clamp(240.0, 360.0);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parts = _DetailParts(anime, ref, context);
    final episodes = parts.episodes;

    return Scaffold(
      backgroundColor: PaheColors.bg,
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: _paneWidth,
              child: _PosterPane(anime: anime, parts: parts),
            ),
            const VerticalDivider(width: 1, color: PaheColors.border),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 12, 4),
                    child: parts.episodesHeader(showLabel: true),
                  ),
                  Expanded(
                    child: episodes.isInitialLoad
                        ? const Center(
                            child: CircularProgressIndicator(
                                color: PaheColors.accent),
                          )
                        : episodes.episodes.isEmpty && episodes.error != null
                            ? parts.errorState
                            : _EpisodeGrid(
                                anime: anime,
                                parts: parts,
                                episodes: episodes.episodes,
                              ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PosterPane extends StatelessWidget {
  final Anime anime;
  final _DetailParts parts;

  const _PosterPane({required this.anime, required this.parts});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _BackButton(dark: false),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  'Back',
                  style: TextStyle(
                    color: PaheColors.textMuted,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Shown at its own aspect ratio and given the pane's full width,
          // rather than shrunk inside a blurred banner.
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: AspectRatio(
              aspectRatio: 2 / 3,
              child: CfImage(url: anime.poster, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            anime.title,
            style: const TextStyle(
              color: PaheColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w800,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 10),
          _InfoRow(anime: anime),
          parts.continueButton,
        ],
      ),
    );
  }
}

/// Episodes as a grid, so a long season fills the width instead of running off
/// the bottom of a single column.
class _EpisodeGrid extends StatelessWidget {
  final Anime anime;
  final _DetailParts parts;
  final List<Episode> episodes;

  const _EpisodeGrid({
    required this.anime,
    required this.parts,
    required this.episodes,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        // Aim for roughly 128px per tile, so the column count follows the
        // window rather than being fixed.
        final columns = (box.maxWidth / 128).floor().clamp(2, 10);
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(20, 4, 12, 20),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            mainAxisExtent: 64,
          ),
          itemCount: episodes.length + 1,
          itemBuilder: (ctx, i) {
            if (i == episodes.length) {
              return parts.loadMore;
            }
            return _EpisodeCell(
              episode: episodes[i],
              anime: anime,
              isWatched: parts.isWatched(episodes[i]),
              siblings: episodes,
            );
          },
        );
      },
    );
  }
}

class _EpisodeCell extends StatelessWidget {
  final Episode episode;
  final Anime anime;
  final bool isWatched;
  final List<Episode> siblings;

  const _EpisodeCell({
    required this.episode,
    required this.anime,
    required this.isWatched,
    required this.siblings,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isWatched ? PaheColors.cardHover : PaheColors.card,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => ResumeRoute.push(context, anime, episode.number),
        onLongPress: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => EpisodePlayerScreen(
              anime: anime,
              episode: episode,
              siblings: siblings,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Text(
                    'EP ${episode.number}',
                    style: TextStyle(
                      color: isWatched
                          ? PaheColors.textMuted
                          : PaheColors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  if (isWatched)
                    const Icon(Icons.check_rounded,
                        size: 14, color: PaheColors.green),
                ],
              ),
              Row(
                children: [
                  Text(
                    episode.isDub ? 'DUB' : 'SUB',
                    style: TextStyle(
                      color: episode.isDub
                          ? PaheColors.accent2
                          : PaheColors.info,
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  Icon(Icons.play_arrow_rounded,
                      size: 16,
                      color: isWatched
                          ? PaheColors.textMuted
                          : PaheColors.accent),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BackButton extends StatelessWidget {
  /// The banner layout needs a chip that reads against artwork; the pane sits
  /// on the app's own background and does not.
  final bool dark;
  const _BackButton({this.dark = true});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: dark
          ? Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.arrow_back_rounded,
                  color: Colors.white, size: 18),
            )
          : const Icon(Icons.arrow_back_rounded,
              color: PaheColors.textMuted, size: 20),
      tooltip: 'Back',
      onPressed: () => Navigator.pop(context),
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
        CfImage(
            url: anime.poster,
            fit: BoxFit.cover),
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(color: Colors.black.withOpacity(0.5)),
        ),
        Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: CfImage(
            url: anime.poster,
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

/// Resumes at the first unwatched episode, or starts the series when there is
/// no progress yet.
///
/// With paged loading the next episode may not be on screen yet, so a missing
/// match means "not loaded" unless every page is in — otherwise resuming at
/// episode 500 would report the series finished after loading only page one.
class _ContinueButton extends StatelessWidget {
  final Anime anime;
  final WatchProgress? progress;
  final EpisodesState state;
  final ValueChanged<EpisodeRange> onJumpToRange;

  const _ContinueButton({
    required this.anime,
    required this.progress,
    required this.state,
    required this.onJumpToRange,
  });

  int get _lastWatched => progress?.lastEpisode ?? 0;

  /// The episode to reopen: the part-watched one if there is one, otherwise
  /// the next unwatched. Resuming matters most in the middle of a long series,
  /// which is where stopping halfway through an episode is most likely.
  int get _targetNumber => progress?.continueEpisode ?? 1;

  /// Episode numbers can skip (specials, gaps), so take the target if it
  /// exists and otherwise the next one that does.
  Episode? get _loadedTarget {
    for (final e in state.episodes) {
      if (e.number == _targetNumber) return e;
    }
    for (final e in state.episodes) {
      if (e.number > _lastWatched) return e;
    }
    return null;
  }

  EpisodeRange? get _rangeHoldingNext {
    final next = _targetNumber;
    for (final r in state.ranges) {
      if (next >= r.firstEpisode && next <= r.lastEpisode) return r;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (state.episodes.isEmpty) return const SizedBox.shrink();

    final target = _loadedTarget;

    // Nothing newer loaded: either genuinely finished, or the next episode
    // lives in a range that has not been fetched.
    if (target == null) {
      if (state.hasMore || state.ranges.isNotEmpty) {
        final range = _rangeHoldingNext;
        if (range != null) {
          return _Banner(
            label: 'Continue — EP $_targetNumber',
            trailing: 'in ${range.label}',
            onTap: () => onJumpToRange(range),
          );
        }
      }
      return Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Row(
          children: [
            const Icon(Icons.check_circle_rounded,
                color: PaheColors.green, size: 18),
            const SizedBox(width: 8),
            Text(
              'All caught up',
              style: const TextStyle(
                color: PaheColors.green,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
    }

    final partial = progress?.hasPartialEpisode ?? false;
    return _Banner(
      label: _lastWatched > 0 || partial
          ? 'Continue — EP ${target.number}'
          : 'Start watching — EP ${target.number}',
      trailing: partial
          ? '${((progress?.resumePosition ?? 0) * 100).round()}% through'
          : (_lastWatched > 0
              ? '$_lastWatched watched'
              : (state.total > 0 ? '${state.total} eps' : null)),
      // Straight into the video: the episode and the preferred quality are
      // both already known, so a source picker in between is just another tap.
      onTap: () => ResumeRoute.push(context, anime, target.number),
    );
  }
}

class _Banner extends StatelessWidget {
  final String label;
  final String? trailing;
  final VoidCallback onTap;

  const _Banner({required this.label, this.trailing, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              gradient: PaheColors.gradient,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                const Icon(Icons.play_arrow_rounded,
                    color: Colors.white, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (trailing != null)
                  Text(
                    trailing!,
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

  /// Passed through so the player can skip to the next episode itself.
  final List<Episode> siblings;

  const _EpisodeTile({
    required this.episode,
    required this.anime,
    required this.isWatched,
    this.siblings = const [],
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
                ? PaheColors.accent.withOpacity(0.2)
                : PaheColors.border,
          ),
          child: Center(
            child: isWatched
                ? const Icon(Icons.check_rounded, color: PaheColors.accent, size: 18)
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
            color: episode.isDub ? PaheColors.accent2 : PaheColors.info,
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
        // Tap plays at the preferred quality; the picker is still reachable
        // for choosing a different one.
        onTap: () => ResumeRoute.push(context, anime, episode.number),
        trailing: IconButton(
          icon: const Icon(Icons.tune_rounded,
              color: PaheColors.textMuted, size: 20),
          tooltip: 'Choose quality or audio',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => EpisodePlayerScreen(
                anime: anime,
                episode: episode,
                siblings: siblings,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EpisodesError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _EpisodesError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final rateLimited = message.contains('429');
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              rateLimited ? 'Slow down a moment' : 'Could not load episodes',
              style: const TextStyle(
                color: PaheColors.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              rateLimited
                  ? 'animepahe is rate limiting us. Give it a few seconds.'
                  : message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: PaheColors.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 14),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}

/// Footer that pulls in the next page of a long series on demand.
class _LoadMore extends StatelessWidget {
  final bool loading;
  final String? error;
  final int loaded;
  final VoidCallback onLoad;

  const _LoadMore({
    required this.loading,
    required this.error,
    required this.loaded,
    required this.onLoad,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Center(
        child: loading
            ? const Padding(
                padding: EdgeInsets.all(10),
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: PaheColors.accent,
                  ),
                ),
              )
            : Column(
                children: [
                  if (error != null) ...[
                    Text(
                      error!.contains('429')
                          ? 'Rate limited — try again in a moment'
                          : 'Could not load more',
                      style: const TextStyle(
                          color: PaheColors.textMuted, fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                  ],
                  OutlinedButton(
                    onPressed: onLoad,
                    child: Text('Load more  ·  $loaded so far'),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Range dropdown for long series — scrolling to episode 900 is not viable.
/// Only shown when a series spans more than one range.
class _RangePicker extends StatelessWidget {
  final List<EpisodeRange> ranges;
  final EpisodeRange selected;
  final ValueChanged<EpisodeRange> onSelected;

  const _RangePicker({
    required this.ranges,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: PaheColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PaheColors.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: selected.index,
          isDense: true,
          borderRadius: BorderRadius.circular(12),
          dropdownColor: PaheColors.surface,
          icon: const Icon(Icons.expand_more_rounded,
              size: 18, color: PaheColors.textSecondary),
          style: const TextStyle(
            color: PaheColors.textPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
          items: [
            for (final r in ranges)
              DropdownMenuItem(value: r.index, child: Text(r.label)),
          ],
          onChanged: (i) {
            if (i == null || i == selected.index) return;
            onSelected(ranges.firstWhere((r) => r.index == i));
          },
        ),
      ),
    );
  }
}
