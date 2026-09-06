import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:percent_indicator/linear_percent_indicator.dart';
import '../models/watch_progress.dart';
import '../services/watch_progress_db.dart';
import '../theme.dart';

final _libraryProvider = FutureProvider<List<WatchProgress>>((ref) async {
  return WatchProgressDb.getAll();
});

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(_libraryProvider);
    return Scaffold(
      backgroundColor: PaheColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'My Library',
                    style: TextStyle(
                      color: PaheColors.textPrimary,
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh_rounded, color: PaheColors.textMuted),
                    onPressed: () => ref.invalidate(_libraryProvider),
                  ),
                ],
              ),
            ),
            Expanded(
              child: library.when(
                loading: () => const Center(
                  child: CircularProgressIndicator(color: PaheColors.purple),
                ),
                error: (e, _) => Center(
                  child: Text('Error: $e',
                      style: const TextStyle(color: PaheColors.textMuted)),
                ),
                data: (list) => list.isEmpty
                    ? _EmptyState()
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: list.length,
                        itemBuilder: (ctx, i) => _LibraryTile(
                          progress: list[i],
                          onDelete: () async {
                            await WatchProgressDb.delete(list[i].animeSession);
                            ref.invalidate(_libraryProvider);
                          },
                        ).animate().fadeIn(delay: Duration(milliseconds: i * 40)),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ShaderMask(
            shaderCallback: (b) => PaheColors.gradient.createShader(b),
            child: const Icon(Icons.collections_bookmark_rounded,
                size: 64, color: Colors.white),
          ),
          const SizedBox(height: 16),
          const Text(
            'Your library is empty',
            style: TextStyle(
              color: PaheColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Start watching to track your progress',
            style: TextStyle(color: PaheColors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _LibraryTile extends StatelessWidget {
  final WatchProgress progress;
  final VoidCallback onDelete;

  const _LibraryTile({required this.progress, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: PaheColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: PaheColors.border),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: CachedNetworkImage(
            imageUrl: progress.animePoster,
            width: 48,
            height: 68,
            fit: BoxFit.cover,
            errorWidget: (_, __, ___) => Container(
              width: 48,
              height: 68,
              color: PaheColors.border,
              child: const Icon(Icons.broken_image_rounded,
                  color: PaheColors.textMuted, size: 20),
            ),
          ),
        ),
        title: Text(
          progress.animeTitle,
          style: const TextStyle(
            color: PaheColors.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text(
              progress.progressLabel,
              style: const TextStyle(
                color: PaheColors.textMuted,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 6),
            LinearPercentIndicator(
              percent: progress.progressFraction.clamp(0, 1),
              lineHeight: 4,
              backgroundColor: PaheColors.border,
              linearGradient: const LinearGradient(
                colors: [PaheColors.purple, PaheColors.pink],
              ),
              barRadius: const Radius.circular(2),
              padding: EdgeInsets.zero,
            ),
          ],
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline_rounded,
              color: PaheColors.textMuted, size: 18),
          onPressed: () => _confirmDelete(context),
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: PaheColors.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Remove from library?',
            style: TextStyle(color: PaheColors.textPrimary)),
        content: Text('This will delete your watch progress for "${progress.animeTitle}".',
            style: const TextStyle(color: PaheColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: PaheColors.textMuted)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              onDelete();
            },
            child: const Text('Remove', style: TextStyle(color: PaheColors.red)),
          ),
        ],
      ),
    );
  }
}
