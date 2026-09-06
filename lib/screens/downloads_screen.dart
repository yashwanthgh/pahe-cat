import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:percent_indicator/linear_percent_indicator.dart';
import '../models/download_item.dart';
import '../services/download_manager.dart';
import '../theme.dart';

class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) {
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
                    'Downloads',
                    style: TextStyle(
                      color: PaheColors.textPrimary,
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => DownloadManager().clearDone(),
                    icon: const Icon(Icons.clear_all_rounded,
                        size: 16, color: PaheColors.textMuted),
                    label: const Text('Clear done',
                        style: TextStyle(color: PaheColors.textMuted, fontSize: 12)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: DownloadManager(),
                builder: (ctx, _) {
                  final queue = DownloadManager().queue;
                  if (queue.isEmpty) {
                    return _EmptyState();
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: queue.length,
                    itemBuilder: (_, i) => ListenableBuilder(
                      listenable: queue[i],
                      builder: (_, __) => _DownloadTile(
                        item: queue[i],
                      ).animate().fadeIn(delay: Duration(milliseconds: i * 30)),
                    ),
                  );
                },
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
            child: const Icon(Icons.download_rounded, size: 64, color: Colors.white),
          ),
          const SizedBox(height: 16),
          const Text(
            'No downloads yet',
            style: TextStyle(
              color: PaheColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Tap the save button on any episode to download it',
            style: TextStyle(color: PaheColors.textMuted),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _DownloadTile extends StatelessWidget {
  final DownloadItem item;
  const _DownloadTile({required this.item});

  Color get _statusColor {
    return switch (item.status) {
      DownloadStatus.completed => PaheColors.green,
      DownloadStatus.failed => PaheColors.red,
      DownloadStatus.cancelled => PaheColors.textMuted,
      DownloadStatus.resolving => PaheColors.amber,
      DownloadStatus.downloading => PaheColors.purple,
      DownloadStatus.queued => PaheColors.textMuted,
    };
  }

  IconData get _statusIcon {
    return switch (item.status) {
      DownloadStatus.completed => Icons.check_circle_rounded,
      DownloadStatus.failed => Icons.error_outline_rounded,
      DownloadStatus.cancelled => Icons.cancel_outlined,
      DownloadStatus.resolving => Icons.hourglass_top_rounded,
      DownloadStatus.downloading => Icons.downloading_rounded,
      DownloadStatus.queued => Icons.schedule_rounded,
    };
  }

  @override
  Widget build(BuildContext context) {
    final isActive = item.status == DownloadStatus.downloading ||
        item.status == DownloadStatus.resolving;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: PaheColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: PaheColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_statusIcon, color: _statusColor, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  item.displayName,
                  style: const TextStyle(
                    color: PaheColors.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (item.canRetry)
                GestureDetector(
                  onTap: () {/* retry logic */},
                  child: const Icon(Icons.refresh_rounded,
                      color: PaheColors.purple, size: 18),
                ),
            ],
          ),
          if (isActive || item.status == DownloadStatus.downloading) ...[
            const SizedBox(height: 10),
            LinearPercentIndicator(
              percent: item.progress.clamp(0, 1),
              lineHeight: 6,
              backgroundColor: PaheColors.border,
              linearGradient: const LinearGradient(
                colors: [PaheColors.purple, PaheColors.pink],
              ),
              barRadius: const Radius.circular(3),
              padding: EdgeInsets.zero,
              animation: isActive && item.status == DownloadStatus.resolving,
              animationDuration: 1500,
            ),
          ],
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                item.progressText,
                style: TextStyle(
                  color: _statusColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (item.isActive)
                GestureDetector(
                  onTap: () => DownloadManager().cancel(item),
                  child: Text(
                    'Cancel',
                    style: TextStyle(
                      color: PaheColors.red.withOpacity(0.8),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
