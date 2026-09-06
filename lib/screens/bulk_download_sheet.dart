import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/anime.dart';
import '../models/episode.dart';
import '../services/download_manager.dart';
import '../services/settings.dart';
import '../theme.dart';

/// Queues an arbitrary span of episodes.
///
/// The common case — the fixed blocks of 25 — is offered directly on the
/// series page, so this exists for the rest: an exact range, or a quality
/// other than the saved preference.
///
/// Only episodes already loaded can be picked, which is what the range
/// dropdown on the series page is for.
class BulkDownloadSheet extends ConsumerStatefulWidget {
  final Anime anime;
  final List<Episode> episodes;
  final int totalEpisodes;

  /// Pre-selected span. Defaults to everything loaded.
  final int? initialFrom;
  final int? initialTo;

  const BulkDownloadSheet({
    super.key,
    required this.anime,
    required this.episodes,
    required this.totalEpisodes,
    this.initialFrom,
    this.initialTo,
  });

  static Future<void> show(
    BuildContext context, {
    required Anime anime,
    required List<Episode> episodes,
    required int totalEpisodes,
    int? initialFrom,
    int? initialTo,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: PaheColors.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => BulkDownloadSheet(
        anime: anime,
        episodes: episodes,
        totalEpisodes: totalEpisodes,
        initialFrom: initialFrom,
        initialTo: initialTo,
      ),
    );
  }

  @override
  ConsumerState<BulkDownloadSheet> createState() => _BulkDownloadSheetState();
}

class _BulkDownloadSheetState extends ConsumerState<BulkDownloadSheet> {
  late int _from;
  late int _to;
  late String _quality;
  late String _audio;

  List<Episode> get _sorted =>
      [...widget.episodes]..sort((a, b) => a.number.compareTo(b.number));

  @override
  void initState() {
    super.initState();
    final list = _sorted;
    _from = widget.initialFrom ?? (list.isEmpty ? 1 : list.first.number);
    _to = widget.initialTo ?? (list.isEmpty ? 1 : list.last.number);
    final s = ref.read(settingsProvider);
    _quality = s.preferredQuality;
    _audio = s.prefersDub ? 'DUB' : 'SUB';
  }

  List<Episode> get _selected =>
      _sorted.where((e) => e.number >= _from && e.number <= _to).toList();

  @override
  Widget build(BuildContext context) {
    final numbers = _sorted.map((e) => e.number).toList();
    final count = _selected.length;

    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Download episodes',
                style: TextStyle(
                  color: PaheColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                widget.anime.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(color: PaheColors.textMuted, fontSize: 12),
              ),
              const SizedBox(height: 18),
              if (numbers.isEmpty)
                const Text(
                  'No episodes loaded yet.',
                  style: TextStyle(color: PaheColors.textMuted, fontSize: 13),
                )
              else ...[
                Row(
                  children: [
                    Expanded(
                      child: _NumberPicker(
                        label: 'From',
                        value: _from,
                        options: numbers,
                        onChanged: (v) => setState(() {
                          _from = v;
                          if (_to < _from) _to = _from;
                        }),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _NumberPicker(
                        label: 'To',
                        value: _to,
                        // Never offer an end before the start.
                        options: numbers.where((n) => n >= _from).toList(),
                        onChanged: (v) => setState(() => _to = v),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _ChoicePicker(
                        label: 'Quality',
                        value: _quality,
                        options: AppSettings.qualities,
                        onChanged: (v) => setState(() => _quality = v),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _ChoicePicker(
                        label: 'Audio',
                        value: _audio,
                        options: const ['SUB', 'DUB'],
                        onChanged: (v) => setState(() => _audio = v),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  'Two download at a time, and each finds its own link when '
                  'its turn comes — animepahe links expire, so resolving a '
                  'whole batch up front would not work. An episode with no '
                  'match for these settings uses the nearest instead of being '
                  'skipped.',
                  style: TextStyle(
                      color: PaheColors.textMuted, fontSize: 11, height: 1.4),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: PaheColors.accent,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: count == 0 ? null : _queue,
                    child: Text(
                      count == 1
                          ? 'Queue EP $_from'
                          : 'Queue $count episodes (EP $_from–$_to)',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _queue() {
    queueEpisodes(
      context,
      anime: widget.anime,
      episodes: _selected,
      totalEpisodes: widget.totalEpisodes,
      quality: _quality,
      audio: _audio,
    );
    Navigator.pop(context);
  }
}

/// Queues [episodes] and says so. Shared with the block buttons on the series
/// page so both paths behave identically.
void queueEpisodes(
  BuildContext context, {
  required Anime anime,
  required List<Episode> episodes,
  required int totalEpisodes,
  required String quality,
  required String audio,
}) {
  if (episodes.isEmpty) return;
  DownloadManager().enqueueBatch(
    animeTitle: anime.title,
    animeSession: anime.session,
    episodes: episodes
        .map((e) => (number: e.number, session: e.session, title: e.title))
        .toList(),
    quality: quality,
    audio: audio,
    totalEpisodes: totalEpisodes,
  );
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text('Queued ${episodes.length} episode'
        '${episodes.length == 1 ? '' : 's'} · $quality $audio'),
    backgroundColor: PaheColors.accent,
  ));
}

class _NumberPicker extends StatelessWidget {
  final String label;
  final int value;
  final List<int> options;
  final ValueChanged<int> onChanged;

  const _NumberPicker({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _Field(
      label: label,
      child: DropdownButton<int>(
        value: options.contains(value) ? value : options.firstOrNull,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        dropdownColor: PaheColors.card,
        style: const TextStyle(color: PaheColors.textPrimary, fontSize: 13),
        items: options
            .map((n) => DropdownMenuItem(value: n, child: Text('EP $n')))
            .toList(),
        onChanged: (v) => v == null ? null : onChanged(v),
      ),
    );
  }
}

class _ChoicePicker extends StatelessWidget {
  final String label;
  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;

  const _ChoicePicker({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _Field(
      label: label,
      child: DropdownButton<String>(
        value: options.contains(value) ? value : options.first,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        dropdownColor: PaheColors.card,
        style: const TextStyle(color: PaheColors.textPrimary, fontSize: 13),
        items: options
            .map((o) => DropdownMenuItem(value: o, child: Text(o)))
            .toList(),
        onChanged: (v) => v == null ? null : onChanged(v),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final Widget child;
  const _Field({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: PaheColors.textMuted,
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: PaheColors.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: PaheColors.border),
          ),
          child: child,
        ),
      ],
    );
  }
}
