import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/anime.dart';
import '../models/episode.dart';
import '../models/stream_source.dart';
import '../services/animepahe_api.dart';
import '../services/settings.dart';
import '../services/providers.dart';
import '../services/watch_progress_db.dart';
import '../theme.dart';
import 'web_player_screen.dart';

/// Goes from "continue this series" straight to playing video.
///
/// Continuing used to take three taps — the card, then the series page, then
/// the source picker — even though every one of those choices was already
/// known: which episode to resume, and which quality and audio the viewer
/// prefers. This does the lookups itself and replaces itself with the player,
/// so continuing is a single tap and the back button returns to where it
/// started rather than to a chain of intermediate screens.
class ResumeRoute extends ConsumerStatefulWidget {
  final Anime anime;

  /// The episode to play. Zero means "whatever the stored progress says".
  final int episodeNumber;

  const ResumeRoute({
    super.key,
    required this.anime,
    this.episodeNumber = 0,
  });

  /// Replaces the current route, so skipping between episodes does not build
  /// up a back stack of every one visited.
  ///
  /// Takes a [NavigatorState] rather than a BuildContext on purpose. The
  /// caller is the player, which this route has already been replaced by, so
  /// the context that started the flow is no longer mounted and
  /// `Navigator.of` on it throws. A NavigatorState stays valid.
  static Future<void> replaceWith(
      NavigatorState nav, Anime anime, int episodeNumber) {
    return nav.pushReplacement(MaterialPageRoute(
      builder: (_) => ResumeRoute(anime: anime, episodeNumber: episodeNumber),
    ));
  }

  static Future<void> push(
      BuildContext context, Anime anime, int episodeNumber) {
    return Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ResumeRoute(anime: anime, episodeNumber: episodeNumber),
    ));
  }

  @override
  ConsumerState<ResumeRoute> createState() => _ResumeRouteState();
}

class _ResumeRouteState extends ConsumerState<ResumeRoute> {
  String _status = 'Finding the episode…';
  Object? _error;

  @override
  void initState() {
    super.initState();
    _go();
  }

  Future<void> _go() async {
    try {
      final target = await _targetEpisodeNumber();
      final found = await _findEpisode(target);
      if (!mounted) return;

      setState(() => _status = 'Getting EP ${found.episode.number} ready…');
      final sources =
          await AnimePaheApi().getSources(widget.anime.session, found.episode.session);
      final source = _preferred(sources);
      if (source == null) {
        throw Exception('No playable source for EP ${found.episode.number}');
      }

      final saved = await WatchProgressDb.getEpisode(
          widget.anime.session, found.episode.number);
      if (!mounted) return;

      final total = widget.anime.episodes > found.total
          ? widget.anime.episodes
          : found.total;

      // Captured before this route goes away, so the skip buttons still have
      // a live navigator to work with.
      final nav = Navigator.of(context);

      await nav.pushReplacement(MaterialPageRoute(
        builder: (_) => WebPlayerScreen(
          kwikUrl: source.kwikUrl,
          title: widget.anime.title,
          subtitle: 'EP ${found.episode.number} · ${source.label}',
          startAt: (saved != null && !saved.isCompleted) ? saved.position : 0,
          onProgress: (fraction) => WatchProgressDb.saveEpisode(
            animeSession: widget.anime.session,
            animeTitle: widget.anime.title,
            animePoster: widget.anime.poster,
            episodeNumber: found.episode.number,
            totalEpisodes: total,
            position: fraction,
          ),
          // Skipping loads the neighbour through this same flow, so it keeps
          // honouring the saved quality and resume position.
          onNext: found.next == null
              ? null
              : () => ResumeRoute.replaceWith(nav, widget.anime, found.next!),
          onPrevious: found.previous == null
              ? null
              : () =>
                  ResumeRoute.replaceWith(nav, widget.anime, found.previous!),
        ),
      ));

      if (!mounted) return;
      ref.invalidate(watchProgressProvider(widget.anime.session));
      ref.invalidate(watchHistoryProvider);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<int> _targetEpisodeNumber() async {
    if (widget.episodeNumber > 0) return widget.episodeNumber;
    final progress = await WatchProgressDb.get(widget.anime.session);
    return progress?.continueEpisode ?? 1;
  }

  /// Locates an episode without walking the whole feed.
  ///
  /// A long series runs to dozens of pages, so the page holding a given
  /// episode is computed from the first page's own page size rather than
  /// paging through from the start.
  Future<_Found> _findEpisode(int number) async {
    final first = await AnimePaheApi().getEpisodes(widget.anime.session, page: 1);
    var page = first;

    if (!_contains(page.episodes, number) && first.perPage > 0) {
      final guess = ((number - 1) ~/ first.perPage) + 1;
      if (guess != 1 && guess <= first.totalPages) {
        page = await AnimePaheApi()
            .getEpisodes(widget.anime.session, page: guess);
      }
    }

    // Numbers can skip — specials and gaps — so fall back to the nearest
    // episode at or after the target rather than failing outright.
    Episode? match;
    for (final e in page.episodes) {
      if (e.number == number) {
        match = e;
        break;
      }
    }
    match ??= page.episodes.where((e) => e.number >= number).fold<Episode?>(
        null, (best, e) => best == null || e.number < best.number ? e : best);
    match ??= page.episodes.isNotEmpty ? page.episodes.last : null;

    if (match == null) {
      throw Exception('No episodes listed for ${widget.anime.title}');
    }

    int? next;
    int? previous;
    for (final e in page.episodes) {
      if (e.number > match.number && (next == null || e.number < next)) {
        next = e.number;
      }
      if (e.number < match.number &&
          (previous == null || e.number > previous)) {
        previous = e.number;
      }
    }
    // Neighbours can sit on the adjacent page; offering the number is enough
    // because this flow looks it up again anyway.
    next ??= match.number < page.total ? match.number + 1 : null;
    previous ??= match.number > 1 ? match.number - 1 : null;

    return _Found(
      episode: match,
      next: next,
      previous: previous,
      total: page.total,
    );
  }

  bool _contains(List<Episode> list, int number) =>
      list.any((e) => e.number == number);

  /// Matches the saved preferences, falling back through audio then quality.
  StreamSource? _preferred(List<StreamSource> sources) {
    final playable = sources.where((s) => s.canStream).toList();
    if (playable.isEmpty) return null;
    final settings = ref.read(settingsProvider);
    final wantDub = settings.prefersDub;
    final wantQ = settings.preferredQuality;

    for (final test in [
      (StreamSource s) => s.isDub == wantDub && s.quality == wantQ,
      (StreamSource s) => s.isDub == wantDub,
      (StreamSource s) => s.quality == wantQ,
    ]) {
      final hit = playable.where(test);
      if (hit.isNotEmpty) return hit.first;
    }
    return playable.first; // sorted sub-first, highest quality first
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: PaheColors.bg,
      appBar: AppBar(leading: const BackButton()),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: _error != null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline_rounded,
                        color: PaheColors.textMuted, size: 32),
                    const SizedBox(height: 12),
                    Text(
                      'Could not start playback.\n$_error',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: PaheColors.textMuted, fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _error = null;
                          _status = 'Finding the episode…';
                        });
                        _go();
                      },
                      child: const Text('Try again'),
                    ),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: PaheColors.accent),
                    const SizedBox(height: 18),
                    Text(
                      widget.anime.title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: PaheColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _status,
                      style: const TextStyle(
                          color: PaheColors.textMuted, fontSize: 12),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _Found {
  final Episode episode;
  final int? next;
  final int? previous;
  final int total;

  const _Found({
    required this.episode,
    required this.next,
    required this.previous,
    required this.total,
  });
}
