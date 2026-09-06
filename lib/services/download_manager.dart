import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/download_item.dart';
import 'cf_session.dart';
import 'settings.dart';

class DownloadManager extends ChangeNotifier {
  static final DownloadManager _i = DownloadManager._();
  DownloadManager._();
  factory DownloadManager() => _i;

  final List<DownloadItem> queue = [];
  final _semaphore = _Semaphore(2);

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: Duration.zero, // streaming — no idle cap
  ));

  /// Where files are written: the folder chosen in Settings, else the
  /// platform default. Read from storage rather than injected so the manager
  /// stays a plain singleton, and so a change in Settings applies to the next
  /// download without a restart.
  Future<String> get saveRoot async {
    final p = await SharedPreferences.getInstance();
    return resolveDownloadDir(p.getString('pref_download_dir') ?? '');
  }

  void enqueue({
    required String animeTitle,
    required int episodeNumber,
    required String quality,
    required String audio,
    required String kwikUrl,
    required String resolvedUrl,
    String episodeTitle = '',
    int totalEpisodes = 0,
  }) {
    final id = '${animeTitle}_${episodeNumber}_${quality}_$audio';
    if (queue.any((i) => i.id == id && i.isActive)) return;

    final item = DownloadItem(
      id: id,
      animeTitle: animeTitle,
      episodeNumber: episodeNumber,
      episodeTitle: episodeTitle,
      totalEpisodes: totalEpisodes,
      quality: quality,
      audio: audio,
      sourceUrl: resolvedUrl,
      kwikUrl: kwikUrl,
    );
    queue.add(item);
    notifyListeners();
    _process(item);
  }

  Future<void> _process(DownloadItem item) async {
    await _semaphore.acquire();
    IOSink? sink;
    try {
      if (item.cancelToken.isCancelled) return;
      item.update(
        status: DownloadStatus.downloading,
        statusMessage: 'Starting…',
      );

      final root = await saveRoot;
      final dir = Directory('$root/${_sanitize(item.animeTitle)}');
      await dir.create(recursive: true);

      final outPath = '${dir.path}/${buildFileName(item)}';
      item.outputPath = outPath;

      if (await File(outPath).exists()) {
        item.update(
          status: DownloadStatus.completed,
          progress: 1.0,
          statusMessage: 'Already downloaded',
        );
        return;
      }

      final tempPath = '$outPath.part';
      final partial = File(tempPath);
      final startByte = await partial.exists() ? await partial.length() : 0;

      final response = await _dio.get<ResponseBody>(
        item.sourceUrl,
        cancelToken: item.cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: true,
          headers: {
            ...CfSession().dioHeaders,
            if (startByte > 0) 'Range': 'bytes=$startByte-',
          },
        ),
      );

      final contentLength =
          int.tryParse(response.headers.value('content-length') ?? '') ?? 0;
      final resumed = response.statusCode == 206 && startByte > 0;

      // content-length covers only the requested range, so the real size is
      // what we already have plus what is still coming.
      final grandTotal = resumed ? startByte + contentLength : contentLength;

      item.update(
        totalBytes: grandTotal,
        downloadedBytes: resumed ? startByte : 0,
      );

      sink = File(tempPath)
          .openWrite(mode: resumed ? FileMode.append : FileMode.write);

      var downloaded = resumed ? startByte : 0;
      var lastTick = DateTime.now();

      await for (final chunk in response.data!.stream) {
        if (item.cancelToken.isCancelled) break;
        sink.add(chunk);
        downloaded += chunk.length;
        final now = DateTime.now();
        if (now.difference(lastTick).inMilliseconds > 250) {
          lastTick = now;
          item.update(
            downloadedBytes: downloaded,
            progress: grandTotal > 0 ? downloaded / grandTotal : 0,
          );
        }
      }

      await sink.flush();
      await sink.close();
      sink = null;

      if (item.cancelToken.isCancelled) {
        item.update(status: DownloadStatus.cancelled, statusMessage: 'Cancelled');
        return;
      }

      await partial.rename(outPath);
      item.update(
        status: DownloadStatus.completed,
        progress: 1.0,
        statusMessage: 'Done',
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        item.update(status: DownloadStatus.cancelled, statusMessage: 'Cancelled');
      } else {
        item.update(
          status: DownloadStatus.failed,
          statusMessage: _friendlyError(e),
        );
      }
    } catch (e) {
      item.update(status: DownloadStatus.failed, statusMessage: 'Failed: $e');
    } finally {
      await sink?.close();
      _semaphore.release();
    }
  }

  /// `Naruto - EP001 - Homecoming [1080p][SUB].mp4`
  ///
  /// Pad width comes from the series' episode count, so every file in a folder
  /// shares one width and sorts correctly: 24 eps -> EP01, 700 -> EP001,
  /// One Piece's 1000+ -> EP0001. Mixed widths would sort EP1000 before EP999.
  /// episodeNumber guards the case where the count is unknown (0) and would
  /// otherwise truncate.
  @visibleForTesting
  static String buildFileName(DownloadItem item) {
    final largest =
        item.totalEpisodes > item.episodeNumber ? item.totalEpisodes : item.episodeNumber;
    final width = largest.toString().length.clamp(2, 5);
    final ep = item.episodeNumber.toString().padLeft(width, '0');
    final title = _sanitize(item.episodeTitle);
    final namePart = title.isEmpty ? '' : ' - $title';
    return '${_sanitize(item.animeTitle)} - EP$ep$namePart'
        ' [${item.quality}][${item.audio.toUpperCase()}].mp4';
  }

  String _friendlyError(DioException e) => switch (e.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.receiveTimeout =>
          'Timed out — check your connection',
        DioExceptionType.badResponse =>
          'Server said ${e.response?.statusCode} — link may have expired',
        DioExceptionType.connectionError => 'No connection',
        _ => 'Failed: ${e.message ?? e.type.name}',
      };

  void cancel(DownloadItem item) {
    if (!item.cancelToken.isCancelled) {
      item.cancelToken.cancel('user cancelled');
    }
    item.update(status: DownloadStatus.cancelled, statusMessage: 'Cancelled');
    notifyListeners();
  }

  void retry(DownloadItem item) {
    if (!item.canRetry) return;
    item.resetForRetry();
    notifyListeners();
    _process(item);
  }

  /// Removes a queue entry, and its half-finished `.part` file if any.
  Future<void> remove(DownloadItem item) async {
    if (item.isActive) cancel(item);
    queue.remove(item);
    notifyListeners();
    if (item.outputPath.isNotEmpty) {
      final part = File('${item.outputPath}.part');
      if (await part.exists()) await part.delete();
    }
  }

  void clearDone() {
    queue.removeWhere((i) => !i.isActive);
    notifyListeners();
  }

  static String _sanitize(String s) => s
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

class _Semaphore {
  final int max;
  int _count = 0;
  final _waiters = <Completer<void>>[];

  _Semaphore(this.max);

  Future<void> acquire() async {
    if (_count < max) {
      _count++;
      return;
    }
    final c = Completer<void>();
    _waiters.add(c);
    await c.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _count--;
    }
  }
}
