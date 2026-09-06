import 'package:flutter/foundation.dart';

enum DownloadStatus { queued, resolving, downloading, completed, failed, cancelled }

class DownloadItem extends ChangeNotifier {
  final String id;
  final String animeTitle;
  final int episodeNumber;
  final String quality;
  final String audio;
  final String sourceUrl;
  String outputPath;

  DownloadStatus _status = DownloadStatus.queued;
  double _progress = 0;
  String _statusMessage = 'Queued';
  int _downloadedBytes = 0;
  int _totalBytes = 0;

  DownloadItem({
    required this.id,
    required this.animeTitle,
    required this.episodeNumber,
    required this.quality,
    required this.audio,
    required this.sourceUrl,
    this.outputPath = '',
  });

  DownloadStatus get status => _status;
  double get progress => _progress;
  String get statusMessage => _statusMessage;
  int get downloadedBytes => _downloadedBytes;
  int get totalBytes => _totalBytes;

  bool get isActive =>
      _status == DownloadStatus.queued ||
      _status == DownloadStatus.resolving ||
      _status == DownloadStatus.downloading;

  bool get canRetry =>
      _status == DownloadStatus.failed ||
      _status == DownloadStatus.cancelled;

  String get displayName =>
      '$animeTitle — EP $episodeNumber ($quality · ${audio.toUpperCase()})';

  String get progressText {
    if (_status == DownloadStatus.resolving) return 'Resolving stream…';
    if (_status == DownloadStatus.downloading && _totalBytes > 0) {
      final dlMB = _downloadedBytes / 1048576;
      final totMB = _totalBytes / 1048576;
      final pct = (_progress * 100).toStringAsFixed(0);
      return '${dlMB.toStringAsFixed(1)} / ${totMB.toStringAsFixed(1)} MB ($pct%)';
    }
    return _statusMessage;
  }

  void update({
    DownloadStatus? status,
    double? progress,
    String? statusMessage,
    int? downloadedBytes,
    int? totalBytes,
  }) {
    if (status != null) _status = status;
    if (progress != null) _progress = progress;
    if (statusMessage != null) _statusMessage = statusMessage;
    if (downloadedBytes != null) _downloadedBytes = downloadedBytes;
    if (totalBytes != null) _totalBytes = totalBytes;
    notifyListeners();
  }
}
