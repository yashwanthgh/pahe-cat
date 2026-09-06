import 'dart:async';
import 'dart:io';
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
  /// Returns the media URL and the page it came from.
  ///
  /// The referer matters: the file is served by kwik's CDN, which refuses a
  /// request that presents animepahe's referer and cookies instead of its
  /// own.
  /// Where the patched macOS plugin writes downloads. Must match the Swift.
  static const tempFolder = 'pahe_cat_downloads';

  static Future<KwikResult> resolve(
    OverlayState overlay,
    String kwikUrl, {
    void Function(int received, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final completer = Completer<KwikResult>();
    late OverlayEntry entry;

    entry = OverlayEntry(
      builder: (_) => _KwikWebView(
        kwikUrl: kwikUrl,
        onProgress: onProgress,
        isCancelled: isCancelled,
        onResolved: (result) {
          if (!completer.isCompleted) completer.complete(result);
        },
        onError: (e) {
          if (!completer.isCompleted) completer.completeError(e);
        },
      ),
    );

    overlay.insert(entry);
    try {
      // Long, because this now covers the transfer itself and a large episode
      // takes minutes. Progress reporting is what catches a genuine stall.
      return await completer.future.timeout(
        const Duration(minutes: 90),
        onTimeout: () => throw TimeoutException(
            'kwik did not hand over the file for $kwikUrl'),
      );
    } finally {
      entry.remove();
    }
  }
}

/// Finds kwik's download page behind the redirector, and stops there.
///
/// Used when the file is going to be handed to the browser anyway: the browser
/// presses the Download button itself, so passing kwik's Cloudflare check and
/// submitting the form in-app is work whose result is thrown away. Stopping at
/// the page turns roughly fifteen seconds into about two.
class KwikPageFinder {
  static Future<String> find(OverlayState overlay, String redirectorUrl) async {
    final completer = Completer<String>();
    late OverlayEntry entry;

    entry = OverlayEntry(
      builder: (_) => _PageFinderView(
        url: redirectorUrl,
        onFound: (page) {
          if (!completer.isCompleted) completer.complete(page);
        },
      ),
    );

    overlay.insert(entry);
    try {
      return await completer.future.timeout(
        const Duration(seconds: 20),
        // The redirector itself is still a usable starting point, just a
        // slower one for whoever opens it.
        onTimeout: () => '',
      );
    } finally {
      entry.remove();
    }
  }
}

class _PageFinderView extends StatefulWidget {
  final String url;
  final ValueChanged<String> onFound;

  const _PageFinderView({required this.url, required this.onFound});

  @override
  State<_PageFinderView> createState() => _PageFinderViewState();
}

class _PageFinderViewState extends State<_PageFinderView> {
  final _key = GlobalKey();
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    // Small but real: the platform throttles work for a view it thinks is
    // invisible, which is what stalled the resolver at one pixel.
    return Positioned(
      right: 16,
      bottom: 16,
      width: 200,
      height: 120,
      child: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(10),
        color: const Color(0xFFFCFBF9),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(
            children: [
              Positioned.fill(
                child: InAppWebView(
                  key: _key,
                  initialUrlRequest: URLRequest(
                    url: WebUri(widget.url),
                    headers: {'Referer': DomainResolver.referer},
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
                  onCreateWindow: (c, req) async => false,
                  // The redirector's adverts must not steal the main frame
                  // before its markup can be read.
                  shouldOverrideUrlLoading: (c, action) async {
                    final host = action.request.url?.host ?? '';
                    if (action.isForMainFrame &&
                        host.isNotEmpty &&
                        !_KwikWebViewState._allowed(host)) {
                      return NavigationActionPolicy.CANCEL;
                    }
                    return NavigationActionPolicy.ALLOW;
                  },
                  onLoadStop: (c, url) async {
                    if (_done) return;
                    try {
                      final r = await c.evaluateJavascript(source: r'''
                        (function () {
                          var a = document.querySelector('a[href*="kwik."]');
                          if (a && a.href) return a.href;
                          var m = document.documentElement.innerHTML.match(
                            /https?:\/\/[^"'\s\\<>]*kwik\.[a-z]{2,6}\/[fd]\/[\w-]+/);
                          return m ? m[0] : '';
                        })()
                      ''');
                      final page = r?.toString().trim() ?? '';
                      if (page.isEmpty || page == 'null') return;
                      _done = true;
                      debugPrint('KWIKPAGE: found $page');
                      widget.onFound(page);
                    } catch (e) {
                      debugPrint('KWIKPAGE: threw $e');
                    }
                  },
                ),
              ),
              const Positioned(
                left: 10,
                right: 10,
                bottom: 8,
                child: Text(
                  'Finding the download…',
                  style: TextStyle(
                    fontSize: 10,
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

/// What a resolution produced.
///
/// [filePath] is set when the WebView actually downloaded the episode, which
/// is the only route the media host permits. The other fields describe the
/// link, and are what a browser hand-off needs when downloading in-app is not
/// available.
class KwikResult {
  final String url;
  final String referer;
  final String page;
  final String filePath;
  final int fileSize;

  const KwikResult({
    this.url = '',
    this.referer = '',
    this.page = '',
    this.filePath = '',
    this.fileSize = 0,
  });

  bool get hasFile => filePath.isNotEmpty;
}

class _KwikWebView extends StatefulWidget {
  final String kwikUrl;
  final ValueChanged<KwikResult> onResolved;
  final ValueChanged<Object> onError;
  final void Function(int received, int total)? onProgress;
  final bool Function()? isCancelled;

  const _KwikWebView({
    required this.kwikUrl,
    required this.onResolved,
    required this.onError,
    this.onProgress,
    this.isCancelled,
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
    r'https?://[^\s"'
    r"'"
    r'\\<>]+?(?:\.mp4|\.mkv|\.m3u8)(?:\?[^\s"'
    r"'"
    r'\\<>]*)?'
    r'|https?://[^\s"'
    r"'"
    r'\\<>]*(?:/get/|workers\.dev)[^\s"'
    r"'"
    r'\\<>]*',
    caseSensitive: false,
  );

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// The page the WebView is on, which becomes the referer for the file.
  String _pageUrl = '';

  /// The media URL, once seen, and when its navigation began.
  String _mediaUrl = '';
  DateTime? _mediaNavigationStartedAt;

  /// kwik's own download page, past the ad gate.
  ///
  /// Reported so a browser hand-off can start here rather than at the
  /// redirector: this page has the Download button on it, with none of the
  /// countdown or the are-you-a-robot step the redirector imposes.
  String _kwikPage = '';

  /// Reports a failure once, and stops everything still running.
  void _fail(Object e) {
    if (_done) return;
    _done = true;
    _poll?.cancel();
    _fileWatch?.cancel();
    debugPrint('KWIK: failed — $e');
    widget.onError(e);
  }

  void _finish(String url, String how, {String filePath = '', int size = 0}) {
    if (_done) return;
    _done = true;
    _poll?.cancel();
    _fileWatch?.cancel();
    debugPrint('KWIK: resolved via $how -> $url (referer $_pageUrl)'
        '${filePath.isEmpty ? '' : ' file=$filePath'}');
    widget.onResolved(KwikResult(
      url: url,
      referer: _pageUrl,
      page: _kwikPage,
      filePath: filePath,
      fileSize: size,
    ));
  }

  /// Watches the file the platform is writing.
  ///
  /// The patched delegate hands WebKit a destination and returns; nothing
  /// reports back when it finishes, so the file itself is the source of truth
  /// for both progress and completion. That is also the most honest signal
  /// available — it is the bytes actually on disk.
  Timer? _fileWatch;
  int _lastSize = -1;
  int _stalledTicks = 0;

  /// True once a transfer is being watched.
  ///
  /// WebKit reports the same download twice — once when the response becomes
  /// a download and again when it asks where to put it — so without this two
  /// timers watched one file, each resetting the other's idea of how far along
  /// it was, and the progress bar walked backwards and forwards.
  bool _watching = false;

  void _watchFile(String path, int expected) {
    if (_watching) return;
    _watching = true;
    _fileWatch?.cancel();
    final file = File(path);

    // WebView2 is Chromium, so on Windows the bytes land in a sibling
    // ".crdownload" file and are renamed to the real name only once the
    // transfer finishes. Watching just `path` there would see nothing at all
    // for the length of the download and call it dead after 30s. WKWebView on
    // macOS writes straight to `path`, so this file never exists and the
    // sizes below simply stay zero.
    final staging = File('$path.crdownload');

    _stalledTicks = 0;
    _lastSize = -1;

    _fileWatch = Timer.periodic(const Duration(milliseconds: 400), (t) async {
      if (_done) {
        t.cancel();
        return;
      }
      if (widget.isCancelled?.call() ?? false) {
        t.cancel();
        _fail(Exception('Cancelled'));
        return;
      }

      int finalSize;
      int stagingSize;
      try {
        finalSize = await file.exists() ? await file.length() : 0;
        stagingSize = await staging.exists() ? await staging.length() : 0;
      } catch (_) {
        return; // being written to; try again
      }
      // Only one of the two is ever growing.
      final size = finalSize > stagingSize ? finalSize : stagingSize;

      widget.onProgress?.call(size, expected);

      // Judged on the file under its final name: on Windows the staging file
      // reaching full length still precedes the rename.
      if (expected > 0 && finalSize >= expected) {
        t.cancel();
        debugPrint('KWIK: file complete at $finalSize bytes');
        _finish(_mediaUrl, 'webview download', filePath: path, size: finalSize);
        return;
      }

      // A file that stops growing well short of its length has failed; one
      // that never appears at all means the patch did not take.
      if (size == _lastSize) {
        _stalledTicks++;

        // With no length to compare against — WebView2 reports -1 when the
        // server sent none — a file that has stopped growing, sits under its
        // final name, and has no staging file beside it is a finished
        // download rather than a stuck one. Two seconds of no growth, so a
        // slow start is not mistaken for the end.
        if (expected <= 0 &&
            finalSize > 0 &&
            stagingSize == 0 &&
            _stalledTicks >= 5) {
          t.cancel();
          debugPrint('KWIK: file settled at $finalSize bytes, no length given');
          _finish(_mediaUrl, 'webview download',
              filePath: path, size: finalSize);
          return;
        }

        if (_stalledTicks > 75) {
          t.cancel();
          _fail(Exception(size == 0
              ? 'The download never started writing'
              : 'The download stopped at $size of $expected bytes'));
        }
      } else {
        _stalledTicks = 0;
        _lastSize = size;
      }
    });
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
      _kwikPage = url;
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
  /// Keeps the shade off for as long as a check is up, across reloads.
  ///
  /// `window.__pcNoShade` lives on `window`, so it does not survive a
  /// navigation — and Cloudflare's check reloads the page as it works. Setting
  /// it once, on the transition into [_needsHuman], therefore held only until
  /// the first reload: after that every fresh document started shaded again and
  /// the check sat under an opaque cover, which is why the panel showed a blank
  /// white area with no box to tick. A user script at document start does
  /// survive, so the flag is installed as one for as long as it is wanted.
  static final _noShadeScript = UserScript(
    source: 'window.__pcNoShade = true;',
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
  );
  bool _noShadeInstalled = false;

  /// Watches both ways: a check appearing, and a check going away again.
  ///
  /// This used to latch. It returned early whenever [_needsHuman] was already
  /// set and never assigned false anywhere, so solving the check left the
  /// enlarged dialog on screen for good — the transfer carried on underneath a
  /// panel that still said a person was needed.
  Future<void> _checkForChallenge(InAppWebViewController c) async {
    try {
      final r = await c.evaluateJavascript(source: r'''
        (function () {
          var t = (document.title || '').toLowerCase();
          if (t.indexOf('just a moment') >= 0 ||
              t.indexOf('attention required') >= 0) return '1';
          if (document.querySelector(
                'iframe[src*="challenges.cloudflare.com"], .cf-turnstile, ' +
                '#challenge-form, #challenge-stage, #turnstile-wrapper')) {
            return '1';
          }
          return '0';
        })()
      ''');
      final challenged = r?.toString().trim() == '1';

      if (challenged) {
        if (!_noShadeInstalled) {
          _noShadeInstalled = true;
          debugPrint('KWIK: kwik is showing a Cloudflare check');
          await c.addUserScript(userScript: _noShadeScript);
        }
        // Re-asserted on every poll, not only on the transition: the script
        // above covers documents loaded from now on, while this uncovers the
        // one already on screen.
        await c.evaluateJavascript(source: 'window.__pcNoShade = true;');
        await c.evaluateJavascript(
            source: "var d=document.getElementById('pc-shade');"
                ' if(d) d.remove();');
      } else if (_noShadeInstalled) {
        _noShadeInstalled = false;
        debugPrint('KWIK: the check cleared, shrinking back');
        await c.removeUserScript(userScript: _noShadeScript);
        // Cover kwik's page again. Unlike the gate, this session never wants
        // the site visible — only the check did.
        await c.evaluateJavascript(source: '''
          window.__pcNoShade = false;
          if (window.__pcApplyShade) window.__pcApplyShade();
        ''');
      }

      if (mounted && challenged != _needsHuman) {
        setState(() => _needsHuman = challenged);
      }
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

    // LayoutBuilder because centring needs a width to centre within. Without
    // one, the panel had `left` and `right` both null and AnimatedPositioned
    // pinned it to 0 — so the dialog that this code says is "centred and
    // large" actually sat jammed against the left edge, half of it off screen.
    return Positioned.fill(
      child: LayoutBuilder(builder: (context, box) {
        const dialogWidth = 460.0;
        const dialogHeight = 560.0;
        final centredLeft = (box.maxWidth - dialogWidth) / 2;
        final centredTop = (box.maxHeight - dialogHeight) / 2;

        return Stack(
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
              // corner while it is only working. Never negative: a window
              // narrower than the dialog would otherwise push it off screen to
              // the left, which is the very thing being fixed here.
              left: _needsHuman ? (centredLeft > 0 ? centredLeft : 0) : null,
              right: _needsHuman ? null : 16,
              bottom: _needsHuman ? null : 16,
              top: _needsHuman ? (centredTop > 0 ? centredTop : 0) : null,
              width: _needsHuman ? dialogWidth : 300,
              height: _needsHuman ? dialogHeight : 190,
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
                          // Fires when the platform decides the response is a
                          // file: proof the host served it.
                          onDownloadStartRequest: (c, req) async {
                            _reportProbe('became a download'
                                ' (${req.contentLength} bytes,'
                                ' ${req.mimeType},'
                                ' "${req.suggestedFilename}")');
                            // The patched delegate is writing it; watch the file
                            // rather than finishing here, and keep this WebView
                            // mounted, because disposing it cancels the
                            // transfer it owns.
                            final name = req.suggestedFilename ?? '';
                            if (name.isEmpty) {
                              _fail(Exception('The download had no filename'));
                              return;
                            }
                            final dir =
                                Directory('${Directory.systemTemp.path}/'
                                    '${KwikResolver.tempFolder}');
                            final path = '${dir.path}/$name';
                            debugPrint('KWIK: watching $path');
                            _watchFile(path, req.contentLength);
                          },
                          onReceivedError: (c, req, err) {
                            if (_mediaUrl.isNotEmpty &&
                                req.url.toString() == _mediaUrl) {
                              _reportProbe('refused: ${err.description}');
                            }
                            debugPrint(
                                'KWIK: error on ${req.url} -> ${err.description}');
                          },
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
        );
      }),
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
        // Makes the platform report a download rather than silently handling
        // it, which is how we learn the host served the file.
        useOnDownloadStart: true,
      );

  Future<NavigationActionPolicy> _shouldOverride(
      InAppWebViewController c, NavigationAction action) async {
    final uri = action.request.url;
    final url = uri?.toString() ?? '';

    if (_media.hasMatch(url)) {
      final media = _media.firstMatch(url)!.group(0)!;
      // Allowed through rather than cancelled, to establish whether the host
      // accepts a real navigation from the session that submitted its form.
      // Cancelling it was reported as "Frame load interrupted", which is our
      // own doing and says nothing about whether the host would have served
      // it — the one fact that decides whether an in-app download is possible
      // at all.
      debugPrint('KWIK PROBE: letting the media navigation proceed -> $media');
      _mediaUrl = media;
      _mediaNavigationStartedAt = DateTime.now();
      return NavigationActionPolicy.ALLOW;
    }

    // Only the main frame is policed; adverts in sub-frames are harmless
    // because they cannot move the page.
    if (action.isForMainFrame) {
      final host = uri?.host ?? '';
      // Remembered before any redirect, so a cancelled media navigation still
      // knows which page asked for it.
      if (host.isNotEmpty && _allowed(host)) _pageUrl = url;
      if (host.isNotEmpty && !_allowed(host)) {
        debugPrint('KWIK: blocked $host');
        return NavigationActionPolicy.CANCEL;
      }
      debugPrint('KWIK: nav -> $url');
    }
    return NavigationActionPolicy.ALLOW;
  }

  /// Reports what the host did with the media navigation.
  void _reportProbe(String outcome) {
    final started = _mediaNavigationStartedAt;
    if (started == null) return;
    final ms = DateTime.now().difference(started).inMilliseconds;
    debugPrint('KWIK PROBE: media navigation -> $outcome after ${ms}ms');
  }

  Future<void> _onLoadStop(InAppWebViewController c, WebUri? url) async {
    debugPrint('KWIK: loaded $url');
    if (url != null && _mediaUrl.isNotEmpty && url.toString() == _mediaUrl) {
      // It loaded as a page: either the file is being displayed, or this is a
      // block page wearing the file's URL. The title tells them apart.
      final title = await c.getTitle();
      final len = await c.evaluateJavascript(
          source: 'document.documentElement.innerHTML.length');
      _reportProbe('loaded as a page, title="$title" htmlLen=$len');
      // Fall through: the resolver still needs to hand something back.
      _finish(_mediaUrl, 'navigation');
      return;
    }
    if (url != null) _pageUrl = url.toString();
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
