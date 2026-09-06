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
/// The WebView is given a real, on-screen size rather than being parked at
/// 1x1 off-screen. A one-pixel off-screen view is throttled by the platform:
/// WebKit stops doing rendering and timer work for something it considers
/// invisible, so the page never finished initialising and resolution timed out
/// every time.
///
/// It is deliberately a small corner panel and not full-screen. Filling the
/// window would blanket the app while a batch resolved one link after another,
/// and the page's own content is hidden from inside the page anyway by
/// [kPageShadeScript], so there is nothing to show.
class KwikResolver {
  /// Resolves [kwikUrl] to a media URL, or throws.
  ///
  /// Takes an [OverlayState] rather than a BuildContext. `Overlay.of` searches
  /// a context's *ancestors*, and a Navigator builds its overlay as a
  /// descendant — so resolving from a navigator's own context found no overlay
  /// and every download failed with "No Overlay widget found". A NavigatorState
  /// hands out the right one directly through `.overlay`.
  static Future<String> resolve(OverlayState overlay, String kwikUrl) async {
    final completer = Completer<String>();
    late OverlayEntry entry;

    entry = OverlayEntry(
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

    overlay.insert(entry);
    try {
      return await completer.future.timeout(
        const Duration(seconds: 45),
        onTimeout: () => throw TimeoutException(
            'kwik did not hand over a media URL for $kwikUrl'),
      );
    } finally {
      entry.remove();
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

  /// True once the page turns out to be a Cloudflare check.
  ///
  /// kwik is a separate origin with its own protection, so reaching its
  /// download page is not the same as being let in. A check cannot complete
  /// inside a small covered panel — the platform throttles work for a view it
  /// thinks is hidden, and the widget has to be visible to be ticked — so the
  /// panel grows and uncovers itself when one appears.
  bool _needsHuman = false;

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

  /// Hosts this flow is allowed to visit.
  ///
  /// `pahe.win` is an ad-gated redirector: its scripts push the main frame off
  /// to an advertiser and it never arrives at kwik, so every resolution timed
  /// out. Only the hosts on the actual path are followed; anything else is
  /// refused.
  static bool _allowed(String host) {
    final h = host.toLowerCase();
    return h == 'pahe.win' ||
        h.endsWith('.pahe.win') ||
        h.contains('kwik.') ||
        h.contains('animepahe.');
  }

  /// Looks for the kwik download page linked from a pahe.win page.
  ///
  /// Following the page's own scripts means following its adverts too, so the
  /// link is taken out of the markup and navigated to directly.
  Future<void> _jumpToKwik(InAppWebViewController c) async {
    try {
      final r = await c.evaluateJavascript(source: r'''
        (function () {
          var a = document.querySelector('a[href*="kwik."]');
          if (a && a.href) return a.href;
          var m = document.documentElement.innerHTML
                    .match(/https?:\/\/[^"'\s\<>]*kwik\.[a-z]{2,6}\/[fd]\/[\w-]+/);
          return m ? m[0] : '';
        })()
      ''');
      final url = r?.toString().trim() ?? '';
      if (url.isEmpty || url == 'null') return;
      debugPrint('KWIK: jumping to $url');
      await c.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    } catch (e) {
      debugPrint('KWIK: jump threw $e');
    }
  }

  /// Polls the live page for the download form.
  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 700), (_) => _probe());
  }

  /// Submits the download form once it exists.
  ///
  /// kwik builds the form in JavaScript after load, so checking a single time
  /// on load stop found nothing; this keeps looking while the page starts up.
  /// Dumped once per page so the form's real shape can be read rather than
  /// guessed at. Resolution reaching kwik and then stalling is exactly the
  /// case where the markup matters.
  bool _dumped = false;

  Future<void> _dump(InAppWebViewController c) async {
    if (_dumped) return;
    _dumped = true;
    try {
      final r = await c.evaluateJavascript(source: r'''
        (function () {
          var out = [];
          out.push('forms=' + document.forms.length);
          for (var i = 0; i < document.forms.length && i < 3; i++) {
            out.push('form' + i + '=' +
              document.forms[i].outerHTML.slice(0, 400));
          }
          var btns = document.querySelectorAll('button, a.button, input[type=submit]');
          out.push('buttons=' + btns.length);
          for (var j = 0; j < btns.length && j < 4; j++) {
            out.push('btn' + j + '=' + btns[j].outerHTML.slice(0, 200));
          }
          var m = document.documentElement.innerHTML
                    .match(/https?:\/\/[^"'\s\<>]*\.mp4[^"'\s\<>]*/);
          out.push('mp4=' + (m ? m[0] : 'none'));
          out.push('title=' + document.title);
          out.push('len=' + document.documentElement.innerHTML.length);
          return out.join(' || ');
        })()
      ''');
      debugPrint('KWIK DUMP: $r');
    } catch (e) {
      debugPrint('KWIK DUMP threw $e');
    }
  }

  /// Detects Cloudflare's interstitial by what it is, not by page size.
  Future<void> _checkForChallenge(InAppWebViewController c) async {
    if (_needsHuman) return;
    try {
      final r = await c.evaluateJavascript(source: r'''
        (function () {
          var t = (document.title || '').toLowerCase();
          if (t.indexOf('just a moment') >= 0 ||
              t.indexOf('attention required') >= 0) return '1';
          if (document.querySelector(
                'iframe[src*="challenges.cloudflare.com"], .cf-turnstile, ' +
                '#challenge-form, #challenge-stage')) return '1';
          return '0';
        })()
      ''');
      if (r?.toString().trim() != '1') return;

      debugPrint('KWIK: kwik is showing a Cloudflare check');
      // Uncover the page so the widget can be seen and clicked.
      await c.evaluateJavascript(source: 'window.__pcNoShade = true;');
      await c.evaluateJavascript(
          source: "var d=document.getElementById('pc-shade'); if(d) d.remove();");
      if (mounted) setState(() => _needsHuman = true);
    } catch (e) {
      debugPrint('KWIK: challenge check threw $e');
    }
  }

  Future<void> _probe() async {
    final c = _c;
    if (c == null || _done || _submitted) return;
    await _dump(c);
    await _checkForChallenge(c);
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

  /// Pins the WebView's element identity.
  ///
  /// Without this, growing the panel rebuilt the WebView under a different
  /// ancestor chain, so Flutter disposed the element and made a new one — the
  /// dialog appeared with a blank page and the challenge it was opened for was
  /// gone. The same trap cost the main Cloudflare gate a whole session once.
  final _webViewKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    // One structure, always. Only geometry and the caption change between the
    // small "preparing" panel and the dialog a person has to act on, so the
    // WebView keeps one set of ancestors either way.
    const headerHeight = 62.0;

    return Positioned.fill(
      child: Stack(
        children: [
          // Present in both states so the tree does not gain or lose a level;
          // invisible and untouchable until it is wanted.
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !_needsHuman,
              child: ColoredBox(
                color: _needsHuman
                    ? const Color(0x99000000)
                    : const Color(0x00000000),
              ),
            ),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            // Centred and large when a person is needed, tucked into the
            // corner while it is only working.
            left: _needsHuman ? null : null,
            right: _needsHuman ? null : 16,
            bottom: _needsHuman ? null : 16,
            top: _needsHuman ? 40 : null,
            width: _needsHuman ? 460 : 300,
            height: _needsHuman ? 560 : 190,
            child: Material(
              elevation: _needsHuman ? 12 : 6,
              borderRadius: BorderRadius.circular(_needsHuman ? 16 : 12),
              color: const Color(0xFFFCFBF9),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(_needsHuman ? 16 : 12),
                child: Stack(
                  children: [
                    // Inset below the header only in the dialog. A padding
                    // value is a property change, not a change of ancestors.
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      top: _needsHuman ? headerHeight : 0,
                      child: InAppWebView(
                        key: _webViewKey,
                        initialUrlRequest: URLRequest(
                          url: WebUri(widget.kwikUrl),
                          headers: {'Referer': DomainResolver.referer},
                        ),
                        initialUserScripts: kShadeUserScripts,
                        initialSettings: _settings,
                        onWebViewCreated: (c) => _c = c,
                        onCreateWindow: (c, req) async => false,
                        shouldOverrideUrlLoading: _shouldOverride,
                        onLoadStop: _onLoadStop,
                        onReceivedError: (c, req, err) => debugPrint(
                            'KWIK: error on ${req.url} -> ${err.description}'),
                      ),
                    ),
                    if (_needsHuman)
                      const Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        height: headerHeight,
                        child: ColoredBox(
                          color: Color(0xFFFCFBF9),
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(18, 12, 18, 6),
                            child: Column(
                              children: [
                                Text(
                                  'One check before the download',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF3A342F),
                                  ),
                                ),
                                SizedBox(height: 3),
                                Text(
                                  'The file host wants to know you are human. '
                                  'Tick the box if one appears.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFF7A716A),
                                    height: 1.3,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      )
                    else
                      const Positioned(
                        left: 12,
                        right: 12,
                        bottom: 10,
                        child: Row(
                          children: [
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Color(0xFF6B615A)),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Preparing download…',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF7A716A),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  InAppWebViewSettings get _settings => InAppWebViewSettings(
        userAgent: CfSession.webViewUserAgent,
        applicationNameForUserAgent: 'Version/17.4 Safari/605.1.15',
        javaScriptEnabled: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        thirdPartyCookiesEnabled: true,
        // Left off deliberately: the redirector uses window-opening to get
        // around the navigation rules below.
        javaScriptCanOpenWindowsAutomatically: false,
        supportMultipleWindows: false,
        mediaPlaybackRequiresUserGesture: false,
        transparentBackground: true,
      );

  Future<NavigationActionPolicy> _shouldOverride(
      InAppWebViewController c, NavigationAction action) async {
    final uri = action.request.url;
    final url = uri?.toString() ?? '';

    if (_media.hasMatch(url)) {
      _finish(_media.firstMatch(url)!.group(0)!, 'navigation');
      return NavigationActionPolicy.CANCEL;
    }

    // Only the main frame is policed; adverts in sub-frames are harmless
    // because they cannot move the page.
    if (action.isForMainFrame) {
      final host = uri?.host ?? '';
      if (host.isNotEmpty && !_allowed(host)) {
        debugPrint('KWIK: blocked $host');
        return NavigationActionPolicy.CANCEL;
      }
      debugPrint('KWIK: nav -> $url');
    }
    return NavigationActionPolicy.ALLOW;
  }

  Future<void> _onLoadStop(InAppWebViewController c, WebUri? url) async {
    debugPrint('KWIK: loaded $url');
    final host = url?.host.toLowerCase() ?? '';
    // The redirector's own page: take the kwik link out of it rather than
    // waiting for scripts that would rather show an advert.
    if (host.endsWith('pahe.win')) {
      await _jumpToKwik(c);
      return;
    }
    // A fresh page may or may not still be a challenge, so this is re-read.
    _dumped = false;
    _startPolling();
    await _probe();
  }

}
