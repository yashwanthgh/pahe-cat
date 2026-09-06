import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart' show CancelToken, DioException, DioExceptionType;
import 'package:flutter/material.dart' show OverlayState;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/download_item.dart';
import '../models/stream_source.dart';
import 'animepahe_api.dart';
import 'kwik_resolver.dart';
import 'settings.dart';
import 'webview_downloader.dart';

class DownloadManager extends ChangeNotifier {
  static final DownloadManager _i = DownloadManager._();
  DownloadManager._();
  factory DownloadManager() => _i;

  final List<DownloadItem> queue = [];
  final _semaphore = _Semaphore(2);

  /// Link resolution runs strictly one at a time, even though two files
  /// transfer at once.
  ///
  /// Resolution drives a real WebView and asks animepahe for the episode's
  /// sources. Queueing a hundred episodes and letting two resolve
  /// concurrently would put two live web pages on screen at once and fire the
  /// source lookups in pairs, which is what animepahe answers with 429.
  /// Transfers are the part worth parallelising; resolution is not.
  final _resolveLock = _Semaphore(1);

  /// Spacing between resolutions, for the same reason.
  static const _resolveGap = Duration(milliseconds: 600);

  /// Where files are written: the folder chosen in Settings, else the
  /// platform default. Read from storage rather than injected so the manager
  /// stays a plain singleton, and so a change in Settings applies to the next
  /// download without a restart.
  Future<String> get saveRoot async {
    final p = await SharedPreferences.getInstance();
    return resolveDownloadDir(p.getString('pref_download_dir') ?? '');
  }

  /// Resolves a download page to a direct file URL.
  ///
  /// Injected because resolution needs a WebView, which needs a widget tree —
  /// something a plain service has no business holding. Set once at startup.
  /// Resolves a download page, and downloads the file when the platform
  /// allows it — see [KwikResult.hasFile].
  Future<KwikResult> Function(
    String downloadPageUrl, {
    void Function(int received, int total)? onProgress,
    bool Function()? isCancelled,
  })? resolver;

  /// Finds kwik's download page without passing its Cloudflare check or
  /// submitting its form — enough for a browser hand-off, and far quicker.
  Future<String> Function(String redirectorUrl)? pageFinder;

  /// Supplies the overlay the transfer's WebView is mounted into.
  ///
  /// The file cannot be fetched by Dart at all — see [WebViewDownloader] — so
  /// downloading needs a widget tree just as resolving does.
  OverlayState? Function()? overlayProvider;

  void enqueue({
    required String animeTitle,
    required int episodeNumber,
    required String quality,
    required String audio,
    required String kwikUrl,
    String resolvedUrl = '',
    String refererUrl = '',
    String kwikPageUrl = '',
    String animeSession = '',
    String episodeSession = '',
    String episodeTitle = '',
    String batchId = '',
    String batchLabel = '',
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
      refererUrl: refererUrl,
      kwikPageUrl: kwikPageUrl,
      kwikUrl: kwikUrl,
      animeSession: animeSession,
      episodeSession: episodeSession,
      batchId: batchId,
      batchLabel: batchLabel,
    );
    queue.add(item);
    // Forwarded so anything watching the manager — the episode tiles, the
    // tab badge, the panel — reacts to progress, not only to items being
    // added and removed. Progress updates are already throttled at the
    // source, so this is not chatty.
    item.addListener(notifyListeners);
    notifyListeners();
    _process(item);
  }

  /// Queues a range of episodes in one go.
  ///
  /// Deliberately queues identities, not links. Resolving a whole season up
  /// front takes minutes of WebView work and the earliest links have expired
  /// by the time their turn arrives, so each item finds its own link when it
  /// reaches the front of the queue.
  void enqueueBatch({
    required String animeTitle,
    required String animeSession,
    required List<({int number, String session, String title})> episodes,
    required String quality,
    required String audio,
    int totalEpisodes = 0,
  }) {
    if (episodes.isEmpty) return;
    final first = episodes.first.number;
    final last = episodes.last.number;
    // Tagged so the whole block can be cancelled in one action instead of
    // clicking through twenty-five rows.
    final batchId = '$animeSession|$first-$last|$quality|$audio'
        '|${DateTime.now().millisecondsSinceEpoch}';
    final batchLabel = 'EP $first–$last · $quality $audio';

    for (final e in episodes) {
      enqueue(
        animeTitle: animeTitle,
        animeSession: animeSession,
        episodeSession: e.session,
        episodeNumber: e.number,
        episodeTitle: e.title,
        totalEpisodes: totalEpisodes,
        quality: quality,
        audio: audio,
        kwikUrl: '',
        batchId: batchId,
        batchLabel: batchLabel,
      );
    }
  }

  /// Cancels every item queued by one action.
  ///
  /// An empty id is the group of one-off downloads — episodes queued
  /// individually rather than as a block — and cancelling that stops all of
  /// them, which is what the group's own control means.
  void cancelBatch(String batchId) {
    for (final item in queue.where((i) => i.batchId == batchId && i.isActive)) {
      cancel(item);
    }
    notifyListeners();
  }

  /// Retries every failed item.
  ///
  /// A batch fails as a batch — one broken assumption takes all twenty-five
  /// with it — so clearing them one at a time is not reasonable.
  void retryFailed() {
    for (final item in queue.where((i) => i.canRetry).toList()) {
      retry(item);
    }
    notifyListeners();
  }

  /// Cancels everything still in flight.
  void cancelAll() {
    for (final item in queue.where((i) => i.isActive)) {
      cancel(item);
    }
    notifyListeners();
  }

  /// The live download for one episode of one series, if any.
  ///
  /// Looked up by episode rather than by the full item id so a tile can show
  /// its state without knowing which quality or audio was queued.
  DownloadItem? forEpisode(String animeSession, int episodeNumber) {
    for (final item in queue) {
      if (item.animeSession == animeSession &&
          item.episodeNumber == episodeNumber &&
          (item.isActive || item.isCompleted)) {
        return item;
      }
    }
    return null;
  }

  /// Active items grouped by the action that queued them, newest group last.
  /// Singles are grouped under an empty key.
  Map<String, List<DownloadItem>> get activeByBatch {
    final out = <String, List<DownloadItem>>{};
    for (final item in queue.where((i) => i.isActive)) {
      out.putIfAbsent(item.batchId, () => []).add(item);
    }
    return out;
  }

  /// Finds this item's download link, at the moment it is needed.
  Future<void> _resolve(DownloadItem item) async {
    final resolve = resolver;
    if (resolve == null) {
      throw StateError('No resolver configured for downloads');
    }
    item.update(
      status: DownloadStatus.resolving,
      statusMessage: 'Waiting to find the file…',
    );

    await _resolveLock.acquire();
    try {
      if (item.cancelToken.isCancelled) return;
      item.update(statusMessage: 'Finding the file…');
      await _resolveOne(item, resolve);
    } finally {
      // Held across the gap so the next item cannot start early.
      await Future.delayed(_resolveGap);
      _resolveLock.release();
    }
  }

  /// The requested quality and audio, falling back so a batch does not stall
  /// on the one episode that lacks a 1080p dub.
  Future<StreamSource> _pickSource(DownloadItem item) async {
    final sources = await AnimePaheApi()
        .getSources(item.animeSession, item.episodeSession);
    final wantDub = item.audio.toUpperCase() == 'DUB';

    StreamSource? pick;
    for (final test in [
      (StreamSource s) => s.isDub == wantDub && s.quality == item.quality,
      (StreamSource s) => s.isDub == wantDub,
      (StreamSource s) => s.quality == item.quality,
    ]) {
      final hit = sources.where((s) => s.canDownload && test(s));
      if (hit.isNotEmpty) {
        pick = hit.first;
        break;
      }
    }
    pick ??= sources.where((s) => s.canDownload).firstOrNull;
    if (pick == null) {
      throw Exception(
          'animepahe lists no download for EP ${item.episodeNumber}');
    }
    return pick;
  }

  Future<void> _resolveOne(
    DownloadItem item,
    Future<KwikResult> Function(
      String, {
      void Function(int received, int total)? onProgress,
      bool Function()? isCancelled,
    }) resolve,
  ) async {
    final pick = await _pickSource(item);
    item.kwikUrl = pick.downloadUrl;

    var lastTick = DateTime.now();
    final resolved = await resolve(
      pick.downloadUrl,
      // Reported from here because the transfer happens during resolution:
      // the WebView that navigates to the file is the only thing the host
      // will serve, and it owns the download until it finishes.
      onProgress: (received, total) {
        final now = DateTime.now();
        if (now.difference(lastTick).inMilliseconds < 250) return;
        lastTick = now;
        item.update(
          status: DownloadStatus.downloading,
          downloadedBytes: received,
          totalBytes: total,
          progress: total > 0 ? received / total : 0,
        );
      },
      isCancelled: () => item.cancelToken.isCancelled,
    );

    item.sourceUrl = resolved.url;
    item.refererUrl = resolved.referer;
    item.kwikPageUrl = resolved.page;
    item.downloadedFilePath = resolved.filePath;
    if (resolved.fileSize > 0) item.update(totalBytes: resolved.fileSize);
  }


  /// True once the media host has refused a transfer, so the rest of a batch
  /// does not spend ten seconds each rediscovering it.
  static bool _transferBlocked = false;

  /// Moves a file the platform downloaded into the library.
  ///
  /// Renamed where possible and copied when the temporary folder is on a
  /// different volume, which rename cannot cross.
  Future<void> _adoptDownloadedFile(DownloadItem item, String outPath) async {
    final source = File(item.downloadedFilePath);
    if (!await source.exists()) {
      throw FileSystemException(
          'The downloaded file is missing', item.downloadedFilePath);
    }
    final size = await source.length();
    try {
      await source.rename(outPath);
    } on FileSystemException {
      await source.copy(outPath);
      await source.delete();
    }
    item.outputPath = outPath;
    item.update(
      status: DownloadStatus.completed,
      progress: 1.0,
      downloadedBytes: size,
      totalBytes: size,
      statusMessage: 'Done',
    );
    debugPrint('DOWNLOAD: saved ${item.episodeNumber} to $outPath');
  }

  /// Finds the download page and hands it straight to the browser.
  Future<void> _findPageThenHandOff(DownloadItem item) async {
    item.update(
      status: DownloadStatus.resolving,
      statusMessage: 'Finding the download…',
    );

    var redirector = item.kwikUrl;
    if (redirector.isEmpty && item.episodeSession.isNotEmpty) {
      // A queued batch carries no link of its own; the play page has it.
      final pick = await _pickSource(item);
      redirector = pick.downloadUrl;
      item.kwikUrl = redirector;
    }
    if (redirector.isEmpty) {
      item.update(
        status: DownloadStatus.failed,
        statusMessage: 'animepahe lists no download for this episode',
      );
      return;
    }

    final find = pageFinder;
    if (find != null) {
      try {
        final page = await find(redirector);
        if (page.isNotEmpty) item.kwikPageUrl = page;
      } catch (e) {
        // The redirector still works as a starting point, just more slowly.
        debugPrint('DOWNLOAD: could not find the download page ($e)');
      }
    }
    await _handToBrowser(item, 'host refuses in-app transfers');
  }

  /// Hands the download to the system browser.
  ///
  /// The *entry* link is handed over, not the resolved file URL. That
  /// distinction is the whole thing: the resolved URL is bound to the session
  /// that submitted kwik's form, so opening it in a browser that has no such
  /// session is refused by Cloudflare with "Sorry, you have been blocked" —
  /// which is what happened. Given the entry link the browser establishes its
  /// own session, and its own Download button works.
  ///
  /// This is the only route left. The plugin's download delegate cancels every
  /// download and reports the URL rather than the bytes, and no request the app
  /// can make is accepted by the host's firewall.
  Future<void> _handToBrowser(DownloadItem item, Object reason) async {
    debugPrint('DOWNLOAD: handing ${item.episodeNumber} to the browser'
        ' ($reason)');
    // kwik's download page for preference: it has the Download button on it
    // and skips the redirector's countdown and robot check, which the app has
    // already been through. The redirector is the fallback when resolution
    // never got that far.
    final entry = item.kwikPageUrl.isNotEmpty
        ? item.kwikPageUrl
        : (item.kwikUrl.isNotEmpty ? item.kwikUrl : item.sourceUrl);
    final uri = Uri.tryParse(entry);
    if (uri == null) {
      item.update(
        status: DownloadStatus.failed,
        statusMessage: 'Could not open the link',
      );
      return;
    }
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      item.update(
        status: ok ? DownloadStatus.openedExternally : DownloadStatus.failed,
        progress: ok ? 1.0 : 0.0,
        statusMessage: ok
            ? 'Opened in your browser — press Download there'
            : 'No browser available to open this',
      );
    } catch (e) {
      item.update(
        status: DownloadStatus.failed,
        statusMessage: 'Could not open your browser: $e',
      );
    }
  }

  /// Creates the series folder, falling back if the chosen root is refused.
  ///
  /// A sandboxed macOS build cannot create a folder in the user's Downloads
  /// without an entitlement, and a folder typed into Settings can be
  /// unwritable for any number of reasons. Failing the download over that
  /// loses the work already done resolving the link, so a location that does
  /// work is used and said so.
  Future<Directory> _prepareDir(DownloadItem item) async {
    final name = _sanitize(item.animeTitle);
    for (final root in [await saveRoot, await _fallbackRoot()]) {
      try {
        final dir = Directory('$root/$name');
        await dir.create(recursive: true);
        return dir;
      } on FileSystemException catch (e) {
        debugPrint('DOWNLOAD: cannot use $root -> ${e.osError?.message}');
        item.update(
          statusMessage: 'Saving somewhere else — $root is not writable',
        );
      }
    }
    throw FileSystemException('No writable download folder', await saveRoot);
  }

  /// Always writable: the app's own container.
  Future<String> _fallbackRoot() async =>
      '${(await getApplicationDocumentsDirectory()).path}/Pahe Cat';

  Future<void> _process(DownloadItem item) async {
    await _semaphore.acquire();
    IOSink? sink;
    try {
      if (item.cancelToken.isCancelled) return;

      // A host known to refuse transfers only needs its download page found,
      // since the browser presses the button. Passing kwik's Cloudflare check
      // and submitting its form would be work thrown away — about fifteen
      // seconds of it, per episode.
      if (_transferBlocked) {
        await _findPageThenHandOff(item);
        return;
      }

      if (item.needsResolving) {
        await _resolve(item);
        if (item.cancelToken.isCancelled) return;
      }

      item.update(
        status: DownloadStatus.downloading,
        statusMessage: 'Starting…',
      );

      final dir = await _prepareDir(item);

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

      // The WebView downloaded it during resolution, which is the only route
      // the media host permits. Move it into place and there is nothing left
      // to transfer.
      if (item.downloadedFilePath.isNotEmpty) {
        await _adoptDownloadedFile(item, outPath);
        return;
      }

      final overlay = overlayProvider?.call();
      if (overlay == null) {
        throw StateError('App is not ready to download yet');
      }

      var resumeFrom = startByte;
      var lastTick = DateTime.now();

      Future<void> transfer() async {
        sink = File(tempPath).openWrite(
            mode: resumeFrom > 0 ? FileMode.append : FileMode.write);
        item.update(
          downloadedBytes: resumeFrom,
          progress: 0,
          statusMessage: 'Downloading…',
        );
        await WebViewDownloader.download(
          overlay: overlay,
          url: item.sourceUrl,
          referer: item.refererUrl,
          startByte: resumeFrom,
          sink: sink!,
          onProgress: (received, total) {
            final now = DateTime.now();
            if (now.difference(lastTick).inMilliseconds < 250) return;
            lastTick = now;
            item.update(
              downloadedBytes: received,
              totalBytes: total,
              progress: total > 0 ? received / total : 0,
            );
          },
          isCancelled: () => item.cancelToken.isCancelled,
        );
        await sink!.flush();
        await sink!.close();
        sink = null;
      }

      try {
        await transfer();
      } on DownloadRefused catch (e) {
        // The host's firewall refuses the app outright; remember it so the
        // rest of a batch does not repeat the discovery.
        _transferBlocked = true;
        await sink?.close();
        sink = null;
        if (await partial.exists()) await partial.delete();
        await _handToBrowser(item, e);
        return;
      } on DownloadNeedsRestart {
        // The host ignored the Range request, so the partial file is useless.
        debugPrint('DOWNLOAD: resume refused, starting over');
        await sink?.close();
        sink = null;
        if (await partial.exists()) await partial.delete();
        resumeFrom = 0;
        await transfer();
      }

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
