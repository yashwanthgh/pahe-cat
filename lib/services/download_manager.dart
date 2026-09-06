import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/download_item.dart';
import 'cf_session.dart';

class DownloadManager extends ChangeNotifier {
  static final DownloadManager _i = DownloadManager._();
  DownloadManager._();
  factory DownloadManager() => _i;

  final List<DownloadItem> queue = [];
  final _semaphore = _Semaphore(2); // 2 concurrent downloads

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 0), // streaming
  ));

  Future<String> get _saveRoot async {
    if (Platform.isAndroid) {
      final dir = await getExternalStorageDirectory();
      return '${dir?.path ?? (await getApplicationDocumentsDirectory()).path}/Pahe Boy';
    }
    final home = Platform.isMacOS || Platform.isLinux
        ? Platform.environment['HOME']!
        : Platform.environment['USERPROFILE']!;
    return '$home/Desktop/Pahe Boy';
  }

  void enqueue({
    required String animeTitle,
    required int episodeNumber,
    required String quality,
    required String audio,
    required String kwikUrl,
    required String resolvedUrl,
  }) {
    final id = '${animeTitle}_${episodeNumber}_$quality';
    if (queue.any((i) => i.id == id && i.isActive)) return;

    final item = DownloadItem(
      id: id,
      animeTitle: animeTitle,
      episodeNumber: episodeNumber,
      quality: quality,
      audio: audio,
      sourceUrl: resolvedUrl,
    );
    queue.add(item);
    notifyListeners();
    _process(item);
  }

  Future<void> _process(DownloadItem item) async {
    await _semaphore.acquire();
    try {
      item.update(
        status: DownloadStatus.downloading,
        statusMessage: 'Starting download…',
      );

      final root = await _saveRoot;
      final dir = Directory('$root/${_sanitize(item.animeTitle)}');
      await dir.create(recursive: true);

      final filename =
          '${_sanitize(item.animeTitle)}.EP${item.episodeNumber.toString().padLeft(2, "0")}.${item.quality}.${item.audio}.mp4';
      final outPath = '${dir.path}/$filename';
      item.outputPath = outPath;

      final tempPath = '$outPath.tmp';
      final existing = File(tempPath);
      final startByte = existing.existsSync() ? existing.lengthSync() : 0;

      final response = await _dio.get<ResponseBody>(
        item.sourceUrl,
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            ...CfSession().dioHeaders,
            if (startByte > 0) 'Range': 'bytes=$startByte-',
          },
        ),
      );

      final total =
          int.tryParse(response.headers.value('content-length') ?? '') ?? 0;
      final resumable = response.statusCode == 206;

      item.update(
        totalBytes: total + (resumable ? startByte : 0),
        downloadedBytes: resumable ? startByte : 0,
      );

      final sink = File(tempPath).openWrite(
        mode: resumable ? FileMode.append : FileMode.write,
      );

      int downloaded = resumable ? startByte : 0;
      DateTime lastUiUpdate = DateTime.now();

      await response.data!.stream.listen(
        (chunk) {
          sink.add(chunk);
          downloaded += chunk.length;
          final now = DateTime.now();
          if (now.difference(lastUiUpdate).inMilliseconds > 250) {
            lastUiUpdate = now;
            item.update(
              downloadedBytes: downloaded,
              progress: total > 0 ? downloaded / total : 0,
            );
          }
        },
        onError: (e) => item.update(
          status: DownloadStatus.failed,
          statusMessage: 'Error: $e',
        ),
        onDone: () async {
          await sink.close();
          await File(tempPath).rename(outPath);
          item.update(
            status: DownloadStatus.completed,
            progress: 1.0,
            statusMessage: 'Done',
          );
        },
        cancelOnError: true,
      ).asFuture();
    } catch (e) {
      item.update(
        status: DownloadStatus.failed,
        statusMessage: 'Failed: $e',
      );
    } finally {
      _semaphore.release();
    }
  }

  void cancel(DownloadItem item) {
    item.update(status: DownloadStatus.cancelled, statusMessage: 'Cancelled');
    notifyListeners();
  }

  void clearDone() {
    queue.removeWhere((i) =>
        i.status == DownloadStatus.completed ||
        i.status == DownloadStatus.cancelled ||
        i.status == DownloadStatus.failed);
    notifyListeners();
  }

  String _sanitize(String s) =>
      s.replaceAll(RegExp(r'[<>:"/\\|?*]'), '').trim();
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
      final c = _waiters.removeAt(0);
      c.complete();
    } else {
      _count--;
    }
  }
}
