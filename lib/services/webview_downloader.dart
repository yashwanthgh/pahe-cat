import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'cf_session.dart';

/// Thrown when the media host refuses the request outright.
class DownloadRefused implements Exception {
  final int status;
  DownloadRefused(this.status);
  @override
  String toString() => 'The file host refused the download (HTTP $status)';
}

/// Thrown when a resume was asked for and the host ignored it.
///
/// A host that answers a Range request with 200 and the whole file, rather
/// than 206 and the tail, would have its response appended to the bytes
/// already on disk — producing a file that is too long and plays as garbage.
/// The caller starts again from zero instead.
class DownloadNeedsRestart implements Exception {
  @override
  String toString() => 'The host ignored the resume request';
}

/// Fetches a media file through a WebView and writes it to disk.
///
/// A plain HTTP client cannot do this. Every header combination — the host's
/// own cookies and referer, no cookies, referer only, bare User-Agent — was
/// answered 403, and each refusal carried `server: cloudflare` and a `cf-ray`.
/// The CDN is fingerprinting the client rather than reading the headers, which
/// is the same wall animepahe's API puts up: nothing sent from Dart's HTTP
/// stack is accepted, whatever it claims to be.
///
/// So the request is made by the WebView, whose TLS handshake and header order
/// Cloudflare does accept, and only the bytes cross into Dart.
///
/// The page is parked on the file's *own* origin first. Reading it from
/// another origin fails the same-origin policy — a browser rule no cookie can
/// get around — which is what stops poster images being read from the main
/// page. On the file's origin the fetch is same-origin and permitted.
///
/// Chosen over the platforms' own download delegates because those are
/// implemented for macOS and Android but not for Windows, and would have left
/// one platform with no working path at all.
class WebViewDownloader {
  /// Bytes accumulated in the page before being handed over. Larger means
  /// fewer, bigger messages; this is a compromise between bridge overhead and
  /// holding a big base64 string in memory.
  static const _chunkBytes = 1024 * 1024;

  /// Downloads [url] into [sink], appending after [startByte].
  ///
  /// Returns the total size when the host reported one, else the number of
  /// bytes written. [onProgress] reports bytes received against that total.
  static Future<int> download({
    required OverlayState overlay,
    required String url,
    required String referer,
    required int startByte,
    required IOSink sink,
    required void Function(int received, int total) onProgress,
    required bool Function() isCancelled,
  }) async {
    final done = Completer<int>();
    late OverlayEntry entry;

    entry = OverlayEntry(
      builder: (_) => _DownloaderView(
        url: url,
        referer: referer,
        startByte: startByte,
        sink: sink,
        onProgress: onProgress,
        isCancelled: isCancelled,
        onDone: (total) {
          if (!done.isCompleted) done.complete(total);
        },
        onError: (e) {
          if (!done.isCompleted) done.completeError(e);
        },
      ),
    );

    overlay.insert(entry);
    try {
      return await done.future;
    } finally {
      entry.remove();
    }
  }
}

class _DownloaderView extends StatefulWidget {
  final String url;
  final String referer;
  final int startByte;
  final IOSink sink;
  final void Function(int received, int total) onProgress;
  final bool Function() isCancelled;
  final ValueChanged<int> onDone;
  final ValueChanged<Object> onError;

  const _DownloaderView({
    required this.url,
    required this.referer,
    required this.startByte,
    required this.sink,
    required this.onProgress,
    required this.isCancelled,
    required this.onDone,
    required this.onError,
  });

  @override
  State<_DownloaderView> createState() => _DownloaderViewState();
}

class _DownloaderViewState extends State<_DownloaderView> {
  /// Pinned: this view is rebuilt as progress arrives, and a WebView that
  /// changes element identity mid-download is a dead download.
  final _webViewKey = GlobalKey();

  int _received = 0;
  int _total = 0;
  bool _started = false;
  bool _finished = false;

  /// The file's own origin, which the page must be on for the fetch to be
  /// same-origin.
  String get _origin {
    final u = Uri.parse(widget.url);
    return '${u.scheme}://${u.host}';
  }

  void _fail(Object e) {
    if (_finished) return;
    _finished = true;
    widget.onError(e);
  }

  void _succeed() {
    if (_finished) return;
    _finished = true;
    widget.onDone(_total > 0 ? _total : widget.startByte + _received);
  }

  void _registerHandlers(InAppWebViewController c) {
    // Reports the response before any bytes, so a refusal is known at once
    // rather than after a zero-byte "success".
    c.addJavaScriptHandler(
      handlerName: 'pcStart',
      callback: (args) {
        final map = (args.isNotEmpty && args.first is Map)
            ? args.first as Map
            : const {};
        final status = (map['status'] as num?)?.toInt() ?? 0;
        final total = (map['total'] as num?)?.toInt() ?? 0;
        final type = (map['type'] ?? '').toString();
        debugPrint('WVDL: status=$status total=$total type=$type');

        if (status < 200 || status >= 300) {
          _fail(DownloadRefused(status));
          return 'stop';
        }
        // A challenge page comes back as HTML with a 200, which would
        // otherwise be written to disk as if it were video.
        if (type.startsWith('text/html')) {
          _fail(Exception('The file host returned a page, not a file'));
          return 'stop';
        }
        // Range was asked for but the whole file came back: appending it to
        // what is already on disk would corrupt the result.
        if (widget.startByte > 0 && status != 206) {
          _fail(DownloadNeedsRestart());
          return 'stop';
        }
        _started = true;
        // content-length covers only the requested range on a resume.
        _total = total > 0 ? widget.startByte + total : 0;
        return 'go';
      },
    );

    // Returning a value makes the page await this, which is the backpressure:
    // the reader cannot outrun the disk.
    c.addJavaScriptHandler(
      handlerName: 'pcChunk',
      callback: (args) {
        if (widget.isCancelled()) return 'stop';
        try {
          final b64 = args.isNotEmpty ? args.first.toString() : '';
          if (b64.isEmpty) return 'go';
          final bytes = base64Decode(b64);
          widget.sink.add(bytes);
          _received += bytes.length;
          widget.onProgress(widget.startByte + _received, _total);
          if (mounted) setState(() {});
          return 'go';
        } catch (e) {
          _fail(e);
          return 'stop';
        }
      },
    );

    c.addJavaScriptHandler(
      handlerName: 'pcEnd',
      callback: (args) {
        final result = args.isNotEmpty ? args.first.toString() : '';
        debugPrint('WVDL: end $result received=$_received');
        if (result == 'ok' && _started) {
          _succeed();
        } else if (!_finished) {
          _fail(Exception('Transfer ended early: $result'));
        }
        return 1;
      },
    );
  }

  /// Runs the transfer inside the page.
  ///
  /// Streamed rather than fetched whole: a 226MB response held as one blob and
  /// then base64-encoded would need most of a gigabyte of memory in the page.
  Future<void> _start(InAppWebViewController c) async {
    if (_started || _finished) return;
    try {
      final r = await c.callAsyncJavaScript(
        functionBody: r'''
          const call = (name, arg) =>
            window.flutter_inappwebview.callHandler(name, arg);

          // Encoded in slices: String.fromCharCode.apply on a whole megabyte
          // overflows the argument list.
          const toBase64 = (bytes) => {
            let s = '';
            const step = 8192;
            for (let i = 0; i < bytes.length; i += step) {
              s += String.fromCharCode.apply(
                null, bytes.subarray(i, i + step));
            }
            return btoa(s);
          };

          let res;
          try {
            res = await fetch(url, {
              credentials: 'include',
              headers: startByte > 0 ? { 'Range': 'bytes=' + startByte + '-' } : {},
            });
          } catch (e) {
            await call('pcEnd', 'fetch failed: ' + e);
            return 'fetch-failed';
          }

          const go = await call('pcStart', {
            status: res.status,
            total: Number(res.headers.get('content-length') || 0),
            type: res.headers.get('content-type') || '',
          });
          if (go !== 'go') {
            await call('pcEnd', 'refused');
            return 'refused';
          }

          const reader = res.body.getReader();
          let pending = [];
          let pendingSize = 0;

          const flush = async () => {
            if (pendingSize === 0) return 'go';
            const merged = new Uint8Array(pendingSize);
            let at = 0;
            for (const part of pending) { merged.set(part, at); at += part.length; }
            pending = [];
            pendingSize = 0;
            // Awaited, so the page cannot read faster than Dart writes.
            return await call('pcChunk', toBase64(merged));
          };

          while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            pending.push(value);
            pendingSize += value.length;
            if (pendingSize >= chunkBytes) {
              if ((await flush()) !== 'go') {
                await call('pcEnd', 'cancelled');
                return 'cancelled';
              }
            }
          }
          if ((await flush()) !== 'go') {
            await call('pcEnd', 'cancelled');
            return 'cancelled';
          }

          await call('pcEnd', 'ok');
          return 'ok';
        ''',
        arguments: {
          'url': widget.url,
          'startByte': widget.startByte,
          'chunkBytes': WebViewDownloader._chunkBytes,
        },
      );
      if (r?.error != null) _fail(Exception('Transfer failed: ${r!.error}'));
    } catch (e) {
      _fail(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pct = _total > 0
        ? ((widget.startByte + _received) / _total * 100).clamp(0, 100)
        : null;

    // A real on-screen size, because the platform throttles work for a view it
    // believes is invisible — which is what stalled the resolver at 1x1. Kept
    // small and out of the way; the page itself is blanked from within.
    return Positioned(
      left: 16,
      bottom: 16,
      width: 240,
      height: 130,
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(12),
        color: const Color(0xFFFCFBF9),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            children: [
              Positioned.fill(
                child: InAppWebView(
                  key: _webViewKey,
                  initialUrlRequest: URLRequest(
                    // Parked on the file's own origin so the fetch below is
                    // same-origin. The page served here does not matter — even
                    // a 404 is on the right origin.
                    url: WebUri('$_origin/favicon.ico'),
                    headers: {
                      if (widget.referer.isNotEmpty) 'Referer': widget.referer,
                    },
                  ),
                  initialUserScripts: kShadeUserScripts,
                  initialSettings: InAppWebViewSettings(
                    userAgent: CfSession.webViewUserAgent,
                    applicationNameForUserAgent: 'Version/17.4 Safari/605.1.15',
                    javaScriptEnabled: true,
                    domStorageEnabled: true,
                    thirdPartyCookiesEnabled: true,
                    javaScriptCanOpenWindowsAutomatically: false,
                    supportMultipleWindows: false,
                    transparentBackground: true,
                  ),
                  onWebViewCreated: _registerHandlers,
                  onLoadStop: (c, url) => _start(c),
                  onReceivedError: (c, req, err) => debugPrint(
                      'WVDL: error on ${req.url} -> ${err.description}'),
                ),
              ),
              Positioned(
                left: 10,
                right: 10,
                bottom: 8,
                child: Text(
                  pct == null
                      ? 'Downloading…'
                      : 'Downloading ${pct.toStringAsFixed(0)}%',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF7A716A),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
