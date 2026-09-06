import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'cf_session.dart';
import 'domain_resolver.dart';

/// Turns a `pahe.win` download link into a direct MP4 URL.
///
/// This handles downloading only. Streaming does not come through here: a
/// kwik `/e/` embed plays HLS through hls.js, so its video element is fed by
/// a MediaSource and its `src` is a `blob:` URL with no file behind it. There
/// was never a link to extract from that page, which is why every attempt to
/// resolve one timed out. Playback runs the embed instead — see
/// `WebPlayerScreen`.
///
/// The download route is real: `pahe.win/<id>` redirects to a kwik download
/// page holding a form that has to be POSTed, and submitting it redirects
/// again to the MP4. kwik will not serve that to a plain HTTP client — it
/// checks the referer and builds the form in JavaScript — so this drives a
/// real WebView.
///
/// The WebView is given real size and left visible behind the app's own
/// loading screen rather than parked at 1x1 off-screen. A one-pixel
/// off-screen view is throttled by the platform: WebKit stops doing rendering
/// and timer work for something it considers invisible, so the player never
/// finished initialising and resolution timed out every time. The page's own
/// content is hidden from inside the page instead, by [kPageShadeScript].
class KwikResolver {
  /// Resolves [kwikUrl] to a media URL, or throws.
  static Future<String> resolve(BuildContext context, String kwikUrl) async {
    final completer = Completer<String>();
    late OverlayEntry overlay;

    overlay = OverlayEntry(
      builder: (_) => _KwikWebView(
        kwikUrl: kwikUrl,
        onResolved: (url) {
          if (!completer.isCompleted) completer.complete(url);
        },
        onError: (e) {
          if (!completer.isCompleted) completer.completeError(e);
        },
      ),
    );

    Overlay.of(context).insert(overlay);
    try {
      return await completer.future.timeout(
        const Duration(seconds: 45),
        onTimeout: () => throw TimeoutException(
            'kwik did not hand over a media URL for $kwikUrl'),
      );
    } finally {
      overlay.remove();
    }
  }
}

class _KwikWebView extends StatefulWidget {
  final String kwikUrl;
  final ValueChanged<String> onResolved;
  final ValueChanged<Object> onError;

  const _KwikWebView({
    required this.kwikUrl,
    required this.onResolved,
    required this.onError,
  });

  @override
  State<_KwikWebView> createState() => _KwikWebViewState();
}

class _KwikWebViewState extends State<_KwikWebView> {
  InAppWebViewController? _c;
  Timer? _poll;
  bool _done = false;
  bool _submitted = false;

  /// Matches the media URLs kwik ends up serving. `/get/` and `workers.dev`
  /// cover the download hand-off, which is not a file extension at all.
  static final _media = RegExp(
    r'https?://[^\s"' r"'" r'\\<>]+?(?:\.mp4|\.mkv|\.m3u8)(?:\?[^\s"' r"'" r'\\<>]*)?'
    r'|https?://[^\s"' r"'" r'\\<>]*(?:/get/|workers\.dev)[^\s"' r"'" r'\\<>]*',
    caseSensitive: false,
  );

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _finish(String url, String how) {
    if (_done) return;
    _done = true;
    _poll?.cancel();
    debugPrint('KWIK: resolved via $how -> $url');
    widget.onResolved(url);
  }

  /// Polls the live page for a media URL.
  ///
  /// kwik's player is built by an obfuscated script that runs after load, so
  /// the URL does not exist in the served HTML — it only appears once the
  /// player has attached it to a <video> element. Checking once on load stop
  /// therefore always came up empty; this keeps looking while the player
  /// starts up.
  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 700), (_) => _probe());
  }

  /// Submits the download form once it exists.
  ///
  /// kwik builds the form in JavaScript after load, so checking a single time
  /// on load stop found nothing; this keeps looking while the page starts up.
  Future<void> _probe() async {
    final c = _c;
    if (c == null || _done || _submitted) return;
    try {
      final r = await c.evaluateJavascript(source: r"""
        (function () {
          var f = document.querySelector('form#dl') ||
                  document.querySelector('form[action*="/f/"]') ||
                  document.querySelector('form[action*="/d/"]') ||
                  document.querySelector('form');
          if (!f) return '0';
          f.submit();
          return '1';
        })()
      """);
      if (r?.toString().trim() == '1') {
        _submitted = true;
        debugPrint('KWIK: submitted the download form');
      }
    } catch (e) {
      debugPrint('KWIK: probe threw $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Full size and visible. The app's own loading UI is drawn over the top of
    // this by the player screen; the page itself is blanked from within.
    return Positioned.fill(
      child: InAppWebView(
        initialUrlRequest: URLRequest(
          url: WebUri(widget.kwikUrl),
          headers: {'Referer': DomainResolver.referer},
        ),
        initialUserScripts: kShadeUserScripts,
        initialSettings: InAppWebViewSettings(
          userAgent: CfSession.webViewUserAgent,
          applicationNameForUserAgent: 'Version/17.4 Safari/605.1.15',
          javaScriptEnabled: true,
          domStorageEnabled: true,
          thirdPartyCookiesEnabled: true,
          // kwik opens the file in a new window on some paths; without this
          // the navigation is silently dropped and nothing is ever resolved.
          javaScriptCanOpenWindowsAutomatically: true,
          supportMultipleWindows: false,
          mediaPlaybackRequiresUserGesture: false,
        ),
        onWebViewCreated: (c) => _c = c,
        shouldOverrideUrlLoading: (c, action) async {
          final url = action.request.url?.toString() ?? '';
          debugPrint('KWIK: nav -> $url');
          if (_media.hasMatch(url)) {
            _finish(_media.firstMatch(url)!.group(0)!, 'navigation');
            return NavigationActionPolicy.CANCEL;
          }
          return NavigationActionPolicy.ALLOW;
        },
        onLoadStop: (c, url) async {
          debugPrint('KWIK: loaded $url');
          _startPolling();
          await _probe();
        },
        // Subresource failures fire here too, so this only reports. Failing
        // the whole resolution on the first one killed pages that were still
        // perfectly able to hand over a URL.
        onReceivedError: (c, req, err) {
          debugPrint('KWIK: error on ${req.url} -> ${err.description}');
        },
      ),
    );
  }
}
