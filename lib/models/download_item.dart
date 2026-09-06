import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

enum DownloadStatus { queued, resolving, downloading, completed, failed, cancelled }

class DownloadItem extends ChangeNotifier {
  final String id;
  final String animeTitle;
  final int episodeNumber;
  final String episodeTitle;
  final int totalEpisodes;
  final String quality;
  final String audio;

  /// The kwik.si page URL. Kept so a retry can re-resolve a link that expired.
  final String kwikUrl;

  /// The direct file URL. Cleared on retry so it gets resolved again.
  String sourceUrl;
  String outputPath;

  /// Recreated on retry — a cancelled token stays cancelled forever.
  CancelToken cancelToken = CancelToken();

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
    this.kwikUrl = '',
    this.episodeTitle = '',
    this.totalEpisodes = 0,
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
      _status == DownloadStatus.failed || _status == DownloadStatus.cancelled;

  bool get isCompleted => _status == DownloadStatus.completed;

  String get displayName =>
      '$animeTitle — EP $episodeNumber ($quality · ${audio.toUpperCase()})';

  String get progressText {
    if (_status == DownloadStatus.resolving) return 'Resolving stream…';
    if (_status == DownloadStatus.downloading && _totalBytes > 0) {
      final dl = _downloadedBytes / 1048576;
      final tot = _totalBytes / 1048576;
      final pct = (_progress * 100).clamp(0, 100).toStringAsFixed(0);
      return '${dl.toStringAsFixed(1)} / ${tot.toStringAsFixed(1)} MB ($pct%)';
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
    if (progress != null) _progress = progress.clamp(0.0, 1.0);
    if (statusMessage != null) _statusMessage = statusMessage;
    if (downloadedBytes != null) _downloadedBytes = downloadedBytes;
    if (totalBytes != null) _totalBytes = totalBytes;
    notifyListeners();
  }

  void resetForRetry() {
    cancelToken = CancelToken();
    _status = DownloadStatus.queued;
    _progress = 0;
    _statusMessage = 'Queued';
    _downloadedBytes = 0;
    _totalBytes = 0;
    notifyListeners();
  }
}
