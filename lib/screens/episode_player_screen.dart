import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../models/anime.dart';
import '../models/episode.dart';
import '../models/stream_source.dart';
import '../models/watch_progress.dart';
import '../services/animepahe_api.dart';
import '../services/kwik_resolver.dart';
import '../services/download_manager.dart';
import '../services/watch_progress_db.dart';
import '../theme.dart';

final _sourcesProvider =
    FutureProvider.family<List<StreamSource>, ({String animeSession, String epSession})>(
  (ref, key) => AnimePaheApi().getSources(key.animeSession, key.epSession),
);

class EpisodePlayerScreen extends ConsumerStatefulWidget {
  final Anime anime;
  final Episode episode;

  const EpisodePlayerScreen({super.key, required this.anime, required this.episode});

  @override
  ConsumerState<EpisodePlayerScreen> createState() => _EpisodePlayerScreenState();
}

class _EpisodePlayerScreenState extends ConsumerState<EpisodePlayerScreen> {
  String? _selectedAudio; // 'sub' or 'dub'
  String? _selectedQuality;
  bool _isResolving = false;

  @override
  Widget build(BuildContext context) {
    final key = (
      animeSession: widget.anime.session,
      epSession: widget.episode.session,
    );
    final sources = ref.watch(_sourcesProvider(key));

    return Scaffold(
      backgroundColor: PaheColors.bg,
      appBar: AppBar(
        title: Text('EP ${widget.episode.number}'),
        leading: const BackButton(),
      ),
      body: sources.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: PaheColors.purple),
        ),
        error: (e, _) => Center(
          child: Text('Failed to load sources: $e',
              style: const TextStyle(color: PaheColors.textMuted)),
        ),
        data: (list) => _SourcePicker(
          anime: widget.anime,
          episode: widget.episode,
          sources: list,
          isResolving: _isResolving,
          onWatch: (src) => _watch(context, src),
          onDownload: (src) => _download(context, src),
        ),
      ),
    );
  }

  Future<void> _watch(BuildContext ctx, StreamSource src) async {
    setState(() => _isResolving = true);
    try {
      final directUrl = await KwikResolver.resolve(ctx, src.kwikUrl);
      if (!ctx.mounted) return;
      // Save watch progress
      await WatchProgressDb.save(WatchProgress(
        animeSession: widget.anime.session,
        animeTitle: widget.anime.title,
        animePoster: widget.anime.poster,
        lastEpisode: widget.episode.number,
        totalEpisodes: widget.anime.episodes,
        updatedAt: DateTime.now(),
      ));
      if (!ctx.mounted) return;
      // Open in external player
      // ignore: use_build_context_synchronously
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(
          content: Text('Opening EP ${widget.episode.number}…'),
          backgroundColor: PaheColors.purple,
        ),
      );
    } catch (e) {
      if (!ctx.mounted) return;
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: PaheColors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _isResolving = false);
    }
  }

  void _download(BuildContext ctx, StreamSource src) {
    KwikResolver.resolve(ctx, src.kwikUrl).then((url) {
      DownloadManager().enqueue(
        animeTitle: widget.anime.title,
        episodeNumber: widget.episode.number,
        quality: src.quality,
        audio: src.audioLabel,
        kwikUrl: src.kwikUrl,
        resolvedUrl: url,
      );
      ScaffoldMessenger.of(ctx).showSnackBar(
        const SnackBar(
          content: Text('Added to downloads'),
          backgroundColor: PaheColors.purple,
        ),
      );
    }).catchError((e) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(
          content: Text('Failed: $e'),
          backgroundColor: PaheColors.red,
        ),
      );
    });
  }
}

class _SourcePicker extends StatefulWidget {
  final Anime anime;
  final Episode episode;
  final List<StreamSource> sources;
  final bool isResolving;
  final ValueChanged<StreamSource> onWatch;
  final ValueChanged<StreamSource> onDownload;

  const _SourcePicker({
    required this.anime,
    required this.episode,
    required this.sources,
    required this.isResolving,
    required this.onWatch,
    required this.onDownload,
  });

  @override
  State<_SourcePicker> createState() => _SourcePickerState();
}

class _SourcePickerState extends State<_SourcePicker> {
  String _audioFilter = 'sub';
  String? _qualityFilter;

  List<StreamSource> get _filtered => widget.sources
      .where((s) =>
          (s.isDub ? 'dub' : 'sub') == _audioFilter &&
          (_qualityFilter == null || s.quality == _qualityFilter))
      .toList();

  Set<String> get _availableQualities =>
      widget.sources.map((s) => s.quality).toSet();

  bool get _hasDub => widget.sources.any((s) => s.isDub);

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Episode info
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: PaheColors.card,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: PaheColors.border),
            ),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    gradient: PaheColors.gradient,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.play_arrow_rounded,
                      color: Colors.white, size: 28),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.anime.title,
                        style: const TextStyle(
                          color: PaheColors.textSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        widget.episode.displayTitle,
                        style: const TextStyle(
                          color: PaheColors.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ).animate().fadeIn(),
          const SizedBox(height: 20),

          // Audio toggle (sub/dub)
          if (_hasDub) ...[
            const Text('Audio',
                style: TextStyle(
                    color: PaheColors.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1)),
            const SizedBox(height: 8),
            Row(
              children: [
                _ToggleBtn(
                  label: 'SUB',
                  active: _audioFilter == 'sub',
                  color: PaheColors.cyan,
                  onTap: () => setState(() => _audioFilter = 'sub'),
                ),
                const SizedBox(width: 8),
                _ToggleBtn(
                  label: 'DUB',
                  active: _audioFilter == 'dub',
                  color: PaheColors.pink,
                  onTap: () => setState(() => _audioFilter = 'dub'),
                ),
              ],
            ),
            const SizedBox(height: 20),
          ],

          // Quality options
          const Text('Quality',
              style: TextStyle(
                  color: PaheColors.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _availableQualities
                .map((q) => _ToggleBtn(
                      label: q,
                      active: _qualityFilter == q,
                      color: PaheColors.purple,
                      onTap: () =>
                          setState(() => _qualityFilter = q == _qualityFilter ? null : q),
                    ))
                .toList(),
          ),
          const SizedBox(height: 24),

          // Source list
          if (_filtered.isEmpty)
            Center(
              child: Text(
                'No $_audioFilter sources available',
                style: const TextStyle(color: PaheColors.textMuted),
              ),
            )
          else
            ...List.generate(
              _filtered.length,
              (i) => _SourceRow(
                source: _filtered[i],
                isResolving: widget.isResolving,
                onWatch: () => widget.onWatch(_filtered[i]),
                onDownload: () => widget.onDownload(_filtered[i]),
              ).animate().slideX(
                    begin: 0.05,
                    delay: Duration(milliseconds: i * 60),
                  ),
            ),
        ],
      ),
    );
  }
}

class _ToggleBtn extends StatelessWidget {
  final String label;
  final bool active;
  final Color color;
  final VoidCallback onTap;

  const _ToggleBtn({
    required this.label,
    required this.active,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: active ? color.withOpacity(0.2) : PaheColors.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: active ? color : PaheColors.border,
            width: active ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? color : PaheColors.textMuted,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  final StreamSource source;
  final bool isResolving;
  final VoidCallback onWatch;
  final VoidCallback onDownload;

  const _SourceRow({
    required this.source,
    required this.isResolving,
    required this.onWatch,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: PaheColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: PaheColors.border),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: PaheColors.purple.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              source.quality,
              style: const TextStyle(
                color: PaheColors.purpleLight,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 10),
          if (source.fileSize.isNotEmpty)
            Text(
              source.fileSize,
              style: const TextStyle(color: PaheColors.textMuted, fontSize: 11),
            ),
          const Spacer(),
          if (isResolving)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: PaheColors.purple,
              ),
            )
          else ...[
            _ActionBtn(
              icon: Icons.play_arrow_rounded,
              label: 'Watch',
              color: PaheColors.purple,
              onTap: onWatch,
            ),
            const SizedBox(width: 8),
            _ActionBtn(
              icon: Icons.download_rounded,
              label: 'Save',
              color: PaheColors.pink,
              onTap: onDownload,
            ),
          ],
        ],
      ),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ActionBtn({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withOpacity(0.15),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 16),
              const SizedBox(width: 4),
              Text(label,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  )),
            ],
          ),
        ),
      ),
    );
  }
}
