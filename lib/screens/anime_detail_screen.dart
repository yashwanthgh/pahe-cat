import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../widgets/cf_image.dart';
import '../models/anime.dart';
import '../models/episode.dart';
import '../models/download_item.dart';
import '../models/watch_progress.dart';
import '../services/download_manager.dart';
import '../services/settings.dart';
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

  Widget episodesHeader({required bool showControls}) {
    final state = episodes;
    return Row(
      children: [
        const Text(
          'EPISODES',
          style: TextStyle(
            color: PaheColors.textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
        if (state.total > 0) ...[
          const SizedBox(width: 8),
          Text(
            '${state.episodes.length} of ${state.total}',
            style: const TextStyle(color: PaheColors.textMuted, fontSize: 11),
          ),
        ],
        const Spacer(),
        // On a wide window these live in the left pane instead, where there is
        // room to label them.
        if (showControls) ...[
          if (state.episodes.isNotEmpty) bulkDownloadButton(icon: true),
          if (state.ranges.isNotEmpty) rangePicker,
        ],
      ],
    );
  }

  Widget get rangePicker {
    final state = episodes;
    if (state.ranges.isEmpty) return const SizedBox.shrink();
    return _RangePicker(
      ranges: state.ranges,
      selected: state.selected ?? state.ranges.first,
      onSelected: notifier.selectRange,
    );
  }

  void openBulkDownload() {
    final state = episodes;
    final visible = state.visibleEpisodes;
    BulkDownloadSheet.show(
      context,
      anime: anime,
      episodes: visible,
      totalEpisodes: state.total > 0 ? state.total : anime.episodes,
      initialFrom: visible.isEmpty ? null : visible.first.number,
      initialTo: visible.isEmpty ? null : visible.last.number,
    );
  }

  Widget bulkDownloadButton({bool icon = false}) {
    return IconButton(
      icon: const Icon(Icons.download_rounded,
          color: PaheColors.accent, size: 20),
      tooltip: 'Download a custom range',
      onPressed: openBulkDownload,
    );
  }

  /// How far through [e] the viewer got, 0 if never opened.
  double positionOf(Episode e) {
    final map = ref.watch(episodeProgressProvider(anime.session)).valueOrNull;
    final recorded = map?[e.number]?.position;
    if (recorded != null) return recorded;
    // Episodes before the furthest reached count as finished even without a
    // row of their own, which is the case for history written before
    // per-episode positions were stored.
    return e.number <= (progress?.lastEpisode ?? 0) ? 1.0 : 0.0;
  }

  /// Says what the rest of the page is doing.
  ///
  /// Replaces a "load more" button: the range fills itself now, so the only
  /// useful things to say are how far along that is, or that it stopped.
  Widget get rangeFooter {
    final state = episodes;
    if (state.error != null && state.episodes.isNotEmpty) {
      return _RangeFooterError(
        message: state.error!,
        onRetry: notifier.retry,
      );
    }
    if (state.loading && state.episodes.isNotEmpty) {
      return _RangeFooterLoading(
        loaded: state.visibleEpisodes.length,
        expected: state.expectedInRange,
      );
    }
    return const SizedBox.shrink();
  }

  Widget get loadMore => rangeFooter;

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
                  _InfoRow(anime: anime, totalEpisodes: episodes.total),
                  parts.continueButton,
                  const SizedBox(height: 20),
                  parts.episodesHeader(showControls: true),
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
                  episode: episodes.visibleEpisodes[i],
                  anime: anime,
                  position: parts.positionOf(episodes.visibleEpisodes[i]),
                  isCurrent: episodes.visibleEpisodes[i].number ==
                      parts.progress?.continueEpisode,
                  siblings: episodes.visibleEpisodes,
                ),
                childCount: episodes.visibleEpisodes.length,
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
              // The panel sits outside the scroll view: while a batch runs it
              // is the thing being watched, and having to scroll the poster
              // pane to find it defeated the purpose.
              child: Column(
                children: [
                  Expanded(child: _PosterPane(anime: anime, parts: parts)),
                  const _DownloadsPanel(),
                ],
              ),
            ),
            const VerticalDivider(width: 1, color: PaheColors.border),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 12, 4),
                    child: parts.episodesHeader(showControls: false),
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
          _InfoRow(anime: anime, totalEpisodes: parts.episodes.total),
          parts.continueButton,
          const _PlaybackPreferences(),
          if (parts.episodes.ranges.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              'EPISODE RANGE',
              style: TextStyle(
                color: PaheColors.textMuted,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(width: double.infinity, child: parts.rangePicker),
          ],
          if (parts.episodes.visibleEpisodes.isNotEmpty) ...[
            const SizedBox(height: 16),
            _DownloadBlocks(anime: anime, parts: parts),
          ],
          const _DownloadsPanel(),
        ],
      ),
    );
  }
}

/// Progress while the rest of the page arrives.
class _RangeFooterLoading extends StatelessWidget {
  final int loaded;
  final int expected;

  const _RangeFooterLoading({required this.loaded, required this.expected});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: PaheColors.accent),
        ),
        const SizedBox(width: 10),
        Text(
          expected > 0
              ? 'Loading the rest of this page — $loaded of $expected'
              : 'Loading more episodes — $loaded so far',
          style: const TextStyle(color: PaheColors.textMuted, fontSize: 11),
        ),
      ],
    );
  }
}

class _RangeFooterError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _RangeFooterError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            // 429 is animepahe throttling a burst, not a real failure.
            message.contains('429')
                ? 'animepahe asked us to slow down; the rest of this page is '
                    'not loaded yet.'
                : 'Could not load the rest of this page.',
            style: const TextStyle(color: PaheColors.textMuted, fontSize: 11),
          ),
        ),
        TextButton(onPressed: onRetry, child: const Text('Try again')),
      ],
    );
  }
}

/// Download buttons, one per block of 25 in the page on screen.
///
/// A single "download episodes" button that opened a sheet asked for the same
/// two numbers every time. The blocks are fixed, so they are just buttons: a
/// 100-episode page gives EP 1-25, 26-50, 51-75, 76-100, and a shorter page
/// gives correspondingly fewer.
class _DownloadBlocks extends StatelessWidget {
  final Anime anime;
  final _DetailParts parts;

  const _DownloadBlocks({required this.anime, required this.parts});

  @override
  Widget build(BuildContext context) {
    final state = parts.episodes;
    final chunks = state.downloadChunks;
    if (chunks.isEmpty) return const SizedBox.shrink();

    final settings = parts.ref.watch(settingsProvider);
    final quality = settings.preferredQuality;
    final audio = settings.prefersDub ? 'DUB' : 'SUB';
    final total = state.total > 0 ? state.total : anime.episodes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'DOWNLOAD',
              style: TextStyle(
                color: PaheColors.textMuted,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
              ),
            ),
            const Spacer(),
            Text(
              '$quality $audio',
              style:
                  const TextStyle(color: PaheColors.textMuted, fontSize: 10),
            ),
          ],
        ),
        const SizedBox(height: 6),
        for (final chunk in chunks) ...[
          _BlockButton(
            label: 'EP ${_pad(chunk.first.number, total)}'
                ' – ${_pad(chunk.last.number, total)}',
            count: chunk.length,
            onTap: () => queueEpisodes(
              context,
              anime: anime,
              episodes: chunk,
              totalEpisodes: total,
              quality: quality,
              audio: audio,
            ),
          ),
          const SizedBox(height: 6),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: parts.openBulkDownload,
            child: const Text(
              'Custom range or quality…',
              style: TextStyle(fontSize: 11, color: PaheColors.accentLight),
            ),
          ),
        ),
      ],
    );
  }

  /// Pads to the width of the series, so a block list reads 01-25 for a short
  /// series and 0001-0025 for One Piece rather than jumping about.
  String _pad(int n, int total) {
    final width = (total > n ? total : n).toString().length.clamp(2, 4);
    return n.toString().padLeft(width, '0');
  }
}

class _BlockButton extends StatelessWidget {
  final String label;
  final int count;
  final VoidCallback onTap;

  const _BlockButton({
    required this.label,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: PaheColors.card,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: PaheColors.border),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: [
                const Icon(Icons.download_rounded,
                    size: 15, color: PaheColors.accent),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: const TextStyle(
                    color: PaheColors.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  '$count',
                  style: const TextStyle(
                      color: PaheColors.textMuted, fontSize: 10),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Audio and quality used by a plain tap on an episode.
///
/// Sits under the poster so the choice is made once, in view, rather than
/// answered again on every episode. It writes the same stored preferences the
/// Settings screen does, so the two cannot disagree.
class _PlaybackPreferences extends ConsumerWidget {
  const _PlaybackPreferences();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'PLAY AS',
            style: TextStyle(
              color: PaheColors.textMuted,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _PrefChip(
                label: 'SUB',
                active: !settings.prefersDub,
                tint: PaheColors.info,
                onTap: () => notifier.setAudio('jpn'),
              ),
              const SizedBox(width: 6),
              _PrefChip(
                label: 'DUB',
                active: settings.prefersDub,
                tint: PaheColors.accent2,
                onTap: () => notifier.setAudio('eng'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              for (final q in AppSettings.qualities) ...[
                _PrefChip(
                  label: q,
                  active: settings.preferredQuality == q,
                  tint: PaheColors.accent,
                  onTap: () => notifier.setQuality(q),
                ),
                if (q != AppSettings.qualities.last) const SizedBox(width: 6),
              ],
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Used when you tap an episode. Long-press one to pick something '
            'else just for it.',
            style: TextStyle(
                color: PaheColors.textMuted, fontSize: 10, height: 1.35),
          ),
        ],
      ),
    );
  }
}

class _PrefChip extends StatelessWidget {
  final String label;
  final bool active;
  final Color tint;
  final VoidCallback onTap;

  const _PrefChip({
    required this.label,
    required this.active,
    required this.tint,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Material(
        color: active ? tint.withValues(alpha: 0.18) : PaheColors.card,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: active ? tint : PaheColors.border,
                width: active ? 1.5 : 1,
              ),
            ),
            padding: const EdgeInsets.symmetric(vertical: 7),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                color: active ? PaheColors.textPrimary : PaheColors.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Live download progress for this window.
///
/// Shown beside the episodes because that is where downloads are started from;
/// having to switch to the Downloads tab to find out whether anything is
/// happening is the thing this avoids.
class _DownloadsPanel extends StatefulWidget {
  const _DownloadsPanel();

  @override
  State<_DownloadsPanel> createState() => _DownloadsPanelState();
}

class _DownloadsPanelState extends State<_DownloadsPanel> {
  final _manager = DownloadManager();

  /// Collapsed by default: one line is enough to know something is happening,
  /// and a queued block of twenty-five would otherwise fill the pane.
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _manager.addListener(_onChange);
  }

  @override
  void dispose() {
    _manager.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final groups = _manager.activeByBatch;
    final active = _manager.queue.where((i) => i.isActive).toList();
    final total = active.length;
    if (total == 0) return const SizedBox.shrink();

    // Overall progress across everything queued, so one bar answers "how far
    // along is this" without expanding.
    final overall =
        active.fold<double>(0, (sum, i) => sum + i.progress) / total;
    final running = active
        .where((i) => i.status == DownloadStatus.downloading)
        .length;

    return DecoratedBox(
      decoration: const BoxDecoration(
        color: PaheColors.surface,
        border: Border(top: BorderSide(color: PaheColors.border)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.download_rounded,
                    size: 15, color: PaheColors.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    running > 0
                        ? '$total downloading'
                        : '$total waiting to download',
                    style: const TextStyle(
                      color: PaheColors.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(
                    _expanded
                        ? Icons.expand_more_rounded
                        : Icons.expand_less_rounded,
                    size: 18,
                    color: PaheColors.textMuted,
                  ),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: _expanded ? 'Hide details' : 'Show details',
                  onPressed: () => setState(() => _expanded = !_expanded),
                ),
                const SizedBox(width: 4),
                TextButton(
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 24),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => _confirmCancelAll(context, total),
                  child: const Text(
                    'Cancel all',
                    style: TextStyle(fontSize: 10, color: PaheColors.red),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: overall,
                minHeight: 4,
                backgroundColor: PaheColors.cardHover,
                valueColor:
                    const AlwaysStoppedAnimation<Color>(PaheColors.accent),
              ),
            ),
            if (_expanded) ...[
              const SizedBox(height: 10),
              // Bounded, so a hundred queued episodes cannot grow the panel
              // over the whole pane.
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final entry in groups.entries)
                        _BatchGroup(batchId: entry.key, items: entry.value),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _confirmCancelAll(BuildContext context, int count) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: PaheColors.card,
        title: const Text('Cancel all downloads?',
            style: TextStyle(color: PaheColors.textPrimary, fontSize: 16)),
        content: Text(
          '$count download${count == 1 ? '' : 's'} will stop. Part-downloaded '
          'files are kept, so retrying resumes rather than starting over.',
          style: const TextStyle(color: PaheColors.textMuted, fontSize: 12),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Keep going')),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Cancel all',
                style: TextStyle(color: PaheColors.red)),
          ),
        ],
      ),
    );
    if (ok == true) DownloadManager().cancelAll();
  }
}

/// One block of downloads, with its own cancel.
class _BatchGroup extends StatelessWidget {
  final String batchId;
  final List<DownloadItem> items;

  const _BatchGroup({required this.batchId, required this.items});

  /// Only the first few rows are drawn, so a queued block of twenty-five does
  /// not push the poster off the top of the pane.
  static const _visibleRows = 3;

  @override
  Widget build(BuildContext context) {
    final label = items.first.batchLabel;
    final hidden = items.length - _visibleRows;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label.isNotEmpty)
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$label · ${items.length} left',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: PaheColors.textSecondary,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                // Cancels this block only.
                IconButton(
                  icon: const Icon(Icons.close_rounded,
                      size: 13, color: PaheColors.textMuted),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Cancel this block',
                  onPressed: () => DownloadManager().cancelBatch(batchId),
                ),
              ],
            ),
          const SizedBox(height: 4),
          for (final item in items.take(_visibleRows))
            _DownloadRow(item: item),
          if (hidden > 0)
            Text(
              '+$hidden more waiting',
              style:
                  const TextStyle(color: PaheColors.textMuted, fontSize: 10),
            ),
        ],
      ),
    );
  }
}

class _DownloadRow extends StatelessWidget {
  final DownloadItem item;
  const _DownloadRow({required this.item});

  @override
  Widget build(BuildContext context) {
    // A resolving item has no measurable progress yet, so it gets an
    // indeterminate bar rather than one frozen at zero.
    final indeterminate = item.status == DownloadStatus.resolving ||
        (item.status == DownloadStatus.downloading && item.totalBytes == 0);

    return ListenableBuilder(
      listenable: item,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'EP ${item.episodeNumber} · ${item.quality}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: PaheColors.textPrimary,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded,
                      size: 14, color: PaheColors.textMuted),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Cancel',
                  onPressed: () => DownloadManager().cancel(item),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: indeterminate ? null : item.progress,
                minHeight: 4,
                backgroundColor: PaheColors.cardHover,
                valueColor:
                    const AlwaysStoppedAnimation<Color>(PaheColors.accent),
              ),
            ),
            const SizedBox(height: 3),
            Text(
              item.progressText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: PaheColors.textMuted, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}

/// Episodes as a grid, so a long season fills the width instead of running off
/// the bottom of a single column.
///
/// Loads the rest of the selected range as it is scrolled. A range labelled
/// "EP 1-120" only ever held the first API page of 30, which made the label a
/// lie; the remaining pages are fetched as the grid is scrolled through them.
class _EpisodeGrid extends ConsumerStatefulWidget {
  final Anime anime;
  final _DetailParts parts;
  final List<Episode> episodes;

  const _EpisodeGrid({
    required this.anime,
    required this.parts,
    required this.episodes,
  });

  @override
  ConsumerState<_EpisodeGrid> createState() => _EpisodeGridState();
}

class _EpisodeGridState extends ConsumerState<_EpisodeGrid> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress =
        ref.watch(episodeProgressProvider(widget.anime.session)).valueOrNull ??
            const <int, EpisodeProgress>{};
    final resumeAt = widget.parts.progress?.continueEpisode;

    return LayoutBuilder(
      builder: (context, box) {
        // Roughly 168px per tile, so the column count follows the window.
        // Tiles were small enough that the episode number and the badges
        // crowded each other.
        final columns = (box.maxWidth / 168).floor().clamp(2, 8);
        return CustomScrollView(
          controller: _scroll,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 4, 12, 0),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  mainAxisExtent: 88,
                ),
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) {
                    final e = widget.episodes[i];
                    return _EpisodeCell(
                      episode: e,
                      anime: widget.anime,
                      position: progress[e.number]?.position ?? 0,
                      isCurrent: e.number == resumeAt,
                      siblings: widget.episodes,
                    );
                  },
                  childCount: widget.episodes.length,
                ),
              ),
            ),
            // Outside the grid: a full-width footer forced into a 70px cell
            // overflowed it.
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(left: 20, right: 12, bottom: 24),
                child: widget.parts.rangeFooter,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// One episode.
///
/// Three states, because "finished", "part-way through" and "not started" are
/// different things and a single greyed-out style could not tell them apart.
/// The tints are pale on purpose — saturated status colours shout on a white
/// app — and the episode to continue from gets a heavier edge so it is
/// findable in a grid of a hundred.
class _EpisodeCell extends StatelessWidget {
  final Episode episode;
  final Anime anime;

  /// 0-1 through this episode.
  final double position;

  final bool isCurrent;
  final List<Episode> siblings;

  const _EpisodeCell({
    required this.episode,
    required this.anime,
    required this.position,
    required this.isCurrent,
    required this.siblings,
  });

  bool get _finished => position >= WatchProgress.completedAt;
  bool get _started => position > 0.02 && !_finished;

  Color get _fill {
    if (_finished) return PaheColors.watchedTint;
    if (_started) return PaheColors.watchingTint;
    return PaheColors.card;
  }

  Color get _edge {
    if (isCurrent) return PaheColors.accent;
    if (_finished) return PaheColors.watchedEdge;
    if (_started) return PaheColors.watchingEdge;
    return PaheColors.border;
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _fill,
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
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _edge,
              width: isCurrent ? 2 : 1,
            ),
          ),
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    'EP ${episode.number}',
                    style: const TextStyle(
                      color: PaheColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  if (_finished)
                    const Icon(Icons.check_circle_rounded,
                        size: 16, color: PaheColors.green)
                  else if (_started)
                    Text(
                      '${(position * 100).round()}%',
                      style: const TextStyle(
                        color: PaheColors.textSecondary,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                ],
              ),
              const Spacer(),
              Row(
                children: [
                  Text(
                    episode.isDub ? 'DUB' : 'SUB',
                    style: TextStyle(
                      color:
                          episode.isDub ? PaheColors.accent2 : PaheColors.info,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    isCurrent
                        ? Icons.play_circle_fill_rounded
                        : Icons.play_arrow_rounded,
                    size: isCurrent ? 20 : 18,
                    color: isCurrent
                        ? PaheColors.accent
                        : PaheColors.textMuted,
                  ),
                ],
              ),
              const SizedBox(height: 7),
              // A hairline rather than a full bar: at this size a thick bar
              // crowds the two lines of text above it.
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: position.clamp(0.0, 1.0),
                  minHeight: 3,
                  backgroundColor: PaheColors.border,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    _finished ? PaheColors.green : PaheColors.accent,
                  ),
                ),
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

  /// From the episode feed, which knows the count even when the record does
  /// not — the airing feed carries no episode total, so this read "0 eps".
  final int totalEpisodes;

  const _InfoRow({required this.anime, this.totalEpisodes = 0});

  int get _count =>
      anime.episodes > totalEpisodes ? anime.episodes : totalEpisodes;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        _Chip(text: anime.type, icon: Icons.tv_rounded),
        if (_count > 0) _Chip(text: '$_count eps'),
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

  /// 0-1 through this episode.
  final double position;
  final bool isCurrent;

  /// Passed through so the player can skip to the next episode itself.
  final List<Episode> siblings;

  const _EpisodeTile({
    required this.episode,
    required this.anime,
    required this.position,
    this.isCurrent = false,
    this.siblings = const [],
  });

  bool get _finished => position >= WatchProgress.completedAt;
  bool get _started => position > 0.02 && !_finished;
  bool get isWatched => _finished;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
      decoration: BoxDecoration(
        // Same three states as the grid: finished, part-watched, untouched.
        color: _finished
            ? PaheColors.watchedTint
            : _started
                ? PaheColors.watchingTint
                : PaheColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isCurrent
              ? PaheColors.accent
              : _finished
                  ? PaheColors.watchedEdge
                  : _started
                      ? PaheColors.watchingEdge
                      : PaheColors.border,
          width: isCurrent ? 2 : 1,
        ),
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
            child: _finished
                ? const Icon(Icons.check_rounded,
                    color: PaheColors.green, size: 18)
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
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  episode.isDub ? 'DUB' : 'SUB',
                  style: TextStyle(
                    color: episode.isDub ? PaheColors.accent2 : PaheColors.info,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (_started) ...[
                  const SizedBox(width: 8),
                  Text(
                    '${(position * 100).round()}% watched',
                    style: const TextStyle(
                        color: PaheColors.textSecondary, fontSize: 10),
                  ),
                ],
              ],
            ),
            if (position > 0) ...[
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: position.clamp(0.0, 1.0),
                  minHeight: 3,
                  backgroundColor: PaheColors.border,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    _finished ? PaheColors.green : PaheColors.accent,
                  ),
                ),
              ),
            ],
          ],
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
