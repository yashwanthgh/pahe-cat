import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../models/anime.dart';
import '../models/episode.dart';
import '../models/stream_source.dart';
import '../services/animepahe_api.dart';
import '../services/kwik_resolver.dart';
import '../services/download_manager.dart';
import '../services/providers.dart';
import '../services/settings.dart';
import '../services/watch_progress_db.dart';
import 'web_player_screen.dart';
import '../theme.dart';

final _sourcesProvider =
    FutureProvider.family<List<StreamSource>, ({String animeSession, String epSession})>(
  (ref, key) => AnimePaheApi().getSources(key.animeSession, key.epSession),
);

class EpisodePlayerScreen extends ConsumerStatefulWidget {
  final Anime anime;
  final Episode episode;

  /// The loaded episode list, so the player can move to the next episode
  /// without going back out to the list and picking again.
  final List<Episode> siblings;

  const EpisodePlayerScreen({
    super.key,
    required this.anime,
    required this.episode,
    this.siblings = const [],
  });

  @override
  ConsumerState<EpisodePlayerScreen> createState() => _EpisodePlayerScreenState();
}

class _EpisodePlayerScreenState extends ConsumerState<EpisodePlayerScreen> {
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
        actions: [
          IconButton(
            icon: const Icon(Icons.skip_previous_rounded),
            tooltip: _previous == null
                ? 'No earlier episode loaded'
                : 'EP ${_previous!.number}',
            onPressed: _previous == null ? null : () => _jumpTo(_previous!),
          ),
          IconButton(
            icon: const Icon(Icons.skip_next_rounded),
            tooltip:
                _next == null ? 'No later episode loaded' : 'EP ${_next!.number}',
            onPressed: _next == null ? null : () => _jumpTo(_next!),
          ),
        ],
      ),
      body: sources.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: PaheColors.accent),
        ),
        error: (e, _) => Center(
          child: Text('Failed to load sources: $e',
              style: const TextStyle(color: PaheColors.textMuted)),
        ),
        data: (list) => _SourcePicker(
          anime: widget.anime,
          episode: widget.episode,
          sources: list,
          settings: ref.watch(settingsProvider),
          isResolving: _isResolving,
          onWatch: (src) => _watch(context, src),
          onDownload: (src) => _download(context, src),
        ),
      ),
    );
  }

  /// Neighbours by episode number rather than list position, because the feed
  /// can contain specials and gaps.
  Episode? get _next {
    Episode? best;
    for (final e in widget.siblings) {
      if (e.number <= widget.episode.number) continue;
      if (best == null || e.number < best.number) best = e;
    }
    return best;
  }

  Episode? get _previous {
    Episode? best;
    for (final e in widget.siblings) {
      if (e.number >= widget.episode.number) continue;
      if (best == null || e.number > best.number) best = e;
    }
    return best;
  }

  /// Replaces this screen rather than stacking, so skipping through several
  /// episodes does not build a back stack of every one visited.
  void _jumpTo(Episode e) {
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => EpisodePlayerScreen(
        anime: widget.anime,
        episode: e,
        siblings: widget.siblings,
      ),
    ));
  }

  void _toast(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? PaheColors.red : PaheColors.accent,
    ));
  }

  /// The series total is 0 on entries that came from the airing feed, which
  /// would render the library bar permanently empty.
  int get _totalEpisodes => widget.anime.episodes > widget.episode.number
      ? widget.anime.episodes
      : widget.episode.number;

  /// Opens the episode in the in-app player.
  ///
  /// The kwik embed does the playing. There is no URL to hand to an external
  /// app: kwik streams HLS through hls.js, so the video element is fed from a
  /// MediaSource and its `src` is a `blob:` URL that means nothing outside
  /// that page. Handing that to url_launcher is what made "watch" do nothing.
  Future<void> _watch(BuildContext ctx, StreamSource src) async {
    if (!src.canStream) {
      _toast('This option can only be downloaded, not streamed.', error: true);
      return;
    }

    // Read before opening, so the player can start where this episode was
    // last left rather than at the beginning.
    final saved = await WatchProgressDb.getEpisode(
        widget.anime.session, widget.episode.number);
    if (!ctx.mounted) return;

    await Navigator.of(ctx).push(MaterialPageRoute(
      builder: (_) => WebPlayerScreen(
        kwikUrl: src.kwikUrl,
        startAt: (saved != null && !saved.isCompleted) ? saved.position : 0,
        title: widget.anime.title,
        subtitle: '${widget.episode.displayTitle} · ${src.label}',
        // Reported when the player closes, so the recorded position is the
        // furthest point actually reached.
        onProgress: (fraction) => WatchProgressDb.saveEpisode(
          animeSession: widget.anime.session,
          animeTitle: widget.anime.title,
          animePoster: widget.anime.poster,
          episodeNumber: widget.episode.number,
          totalEpisodes: _totalEpisodes,
          position: fraction,
        ),
      ),
    ));

    if (!mounted) return;
    ref.invalidate(watchProgressProvider(widget.anime.session));
    ref.invalidate(watchHistoryProvider);
  }

  Future<void> _download(BuildContext ctx, StreamSource src) async {
    setState(() => _isResolving = true);
    try {
      if (!src.canDownload) {
        _toast('animepahe lists no download for this option.', error: true);
        return;
      }
      // The download menu's link, never the embed: only this route ends at a
      // real file.
      final url = await KwikResolver.resolve(Overlay.of(ctx), src.downloadUrl);
      DownloadManager().enqueue(
        animeTitle: widget.anime.title,
        episodeNumber: widget.episode.number,
        episodeTitle: widget.episode.title,
        totalEpisodes: _totalEpisodes,
        quality: src.quality,
        audio: src.audioLabel,
        kwikUrl: src.downloadUrl,
        resolvedUrl: url,
      );
      _toast('Added EP ${widget.episode.number} to downloads');
    } catch (e) {
      _toast('Could not queue download: $e', error: true);
    } finally {
      if (mounted) setState(() => _isResolving = false);
    }
  }
}

class _SourcePicker extends StatefulWidget {
  final Anime anime;
  final Episode episode;
  final List<StreamSource> sources;
  final AppSettings settings;
  final bool isResolving;
  final ValueChanged<StreamSource> onWatch;
  final ValueChanged<StreamSource> onDownload;

  const _SourcePicker({
    required this.anime,
    required this.episode,
    required this.sources,
    required this.settings,
    required this.isResolving,
    required this.onWatch,
    required this.onDownload,
  });

  @override
  State<_SourcePicker> createState() => _SourcePickerState();
}

class _SourcePickerState extends State<_SourcePicker> {
  late String _audioFilter;
  String? _qualityFilter;

  @override
  void initState() {
    super.initState();
    // Start on the saved preferences, but only where they actually exist for
    // this episode — otherwise the picker opens on an empty list.
    final wantDub = widget.settings.prefersDub;
    _audioFilter =
        (wantDub && widget.sources.any((s) => s.isDub)) ? 'dub' : 'sub';
    final wantQ = widget.settings.preferredQuality;
    if (widget.sources.any((s) => s.quality == wantQ)) _qualityFilter = wantQ;
  }

  /// The source matching the saved preferences, or the best available.
  ///
  /// Having set a preference in Settings and then being asked again on every
  /// episode is the thing to avoid: this backs a single button that just
  /// plays, with the full list still below for anything unusual.
  StreamSource? get _preferred {
    final playable = widget.sources.where((s) => s.canStream).toList();
    if (playable.isEmpty) return null;
    final wantDub = widget.settings.prefersDub;
    final wantQ = widget.settings.preferredQuality;

    for (final test in [
      (StreamSource s) => s.isDub == wantDub && s.quality == wantQ,
      (StreamSource s) => s.isDub == wantDub,
      (StreamSource s) => s.quality == wantQ,
    ]) {
      final hit = playable.where(test);
      if (hit.isNotEmpty) return hit.first;
    }
    // Already sorted sub-first, highest quality first.
    return playable.first;
  }

  List<StreamSource> get _filtered => widget.sources
      .where((s) =>
          (s.isDub ? 'dub' : 'sub') == _audioFilter &&
          (_qualityFilter == null || s.quality == _qualityFilter))
      .toList();

  /// Ordered high to low, so the quality chips are not in hash order.
  List<String> get _availableQualities {
    final set = widget.sources.map((s) => s.quality).toSet().toList();
    set.sort((a, b) =>
        (int.tryParse(b.replaceAll(RegExp(r'[^0-9]'), '')) ?? -1) -
        (int.tryParse(a.replaceAll(RegExp(r'[^0-9]'), '')) ?? -1));
    return set;
  }

  bool get _hasDub => widget.sources.any((s) => s.isDub);
  bool get _hasSub => widget.sources.any((s) => !s.isDub);

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
          const SizedBox(height: 16),

          // One tap to play what Settings already asked for.
          if (_preferred != null)
            _PlayNowButton(
              source: _preferred!,
              busy: widget.isResolving,
              onTap: () => widget.onWatch(_preferred!),
            ),
          const SizedBox(height: 20),

          // Audio choice. Always shown, with whatever this episode does not
          // offer visibly disabled — hiding the row entirely read as the
          // feature being missing rather than the dub not existing.
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
                color: PaheColors.info,
                enabled: _hasSub,
                onTap: () => setState(() => _audioFilter = 'sub'),
              ),
              const SizedBox(width: 8),
              _ToggleBtn(
                label: 'DUB',
                active: _audioFilter == 'dub',
                color: PaheColors.accent2,
                enabled: _hasDub,
                onTap: () => setState(() => _audioFilter = 'dub'),
              ),
              if (!_hasDub) ...[
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'No dub for this episode',
                    style: TextStyle(
                        color: PaheColors.textMuted, fontSize: 11),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 20),

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
                      color: PaheColors.accent,
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

/// The primary action: plays the preferred source without further choices.
class _PlayNowButton extends StatelessWidget {
  final StreamSource source;
  final bool busy;
  final VoidCallback onTap;

  const _PlayNowButton({
    required this.source,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Material(
        borderRadius: BorderRadius.circular(14),
        color: PaheColors.accent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: busy ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (busy)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                else
                  const Icon(Icons.play_arrow_rounded,
                      color: Colors.white, size: 22),
                const SizedBox(width: 8),
                Text(
                  busy ? 'Starting…' : 'Play ${source.quality} ${source.audioLabel}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ToggleBtn extends StatelessWidget {
  final String label;
  final bool active;
  final Color color;

  /// A choice this episode does not offer is shown greyed rather than removed,
  /// so its absence reads as "not available here" instead of "not built".
  final bool enabled;
  final VoidCallback onTap;

  const _ToggleBtn({
    required this.label,
    required this.active,
    required this.color,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: GestureDetector(
      onTap: enabled ? onTap : null,
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
              color: PaheColors.accent.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              source.quality,
              style: const TextStyle(
                color: PaheColors.accentLight,
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
                color: PaheColors.accent,
              ),
            )
          else ...[
            _ActionBtn(
              icon: Icons.play_arrow_rounded,
              label: 'Watch',
              color: PaheColors.accent,
              onTap: onWatch,
            ),
            const SizedBox(width: 8),
            _ActionBtn(
              icon: Icons.download_rounded,
              label: 'Save',
              color: PaheColors.accent2,
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
