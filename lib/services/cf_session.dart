import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'domain_resolver.dart';

/// Holds the cleared Cloudflare session and runs requests through it.
///
/// Copying `cf_clearance` into a normal HTTP client is not enough: Cloudflare
/// also fingerprints the TLS handshake and header order, so the same cookie
/// sent from Dart's HTTP client still comes back 403. Requests therefore run
/// as `fetch` inside the WebView that passed the challenge, which carries the
/// right cookies, User-Agent and TLS fingerprint by construction.
class CfSession {
  static final CfSession _instance = CfSession._();
  CfSession._();
  factory CfSession() => _instance;

  InAppWebViewController? _controller;

  bool _ready = false;
  String? _uaFromWebView;

  bool get isReady => _ready && _controller != null;

  /// Overriding the User-Agent is only safe where it matches the engine
  /// actually rendering the page. Android's WebView is Chromium, so a Chrome
  /// UA is truthful. macOS and iOS use WKWebView (Safari), and claiming to be
  /// Chrome there is a UA/engine contradiction that Cloudflare fingerprints —
  /// it answered every API call with 403 on macOS while Android worked. An
  /// empty string leaves the platform's own UA in place.
  static String get webViewUserAgent {
    if (kIsWeb) return '';
    if (Platform.isAndroid) return defaultUserAgent;
    return ''; // let WKWebView and the desktop engines speak for themselves
  }

  /// Set on the WebView before any page exists to read a UA from.
  static String get defaultUserAgent {
    const chrome = 'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0';
    if (kIsWeb) return 'Mozilla/5.0 $chrome Safari/537.36';
    if (Platform.isAndroid) {
      return 'Mozilla/5.0 (Linux; Android 13; Pixel 7) $chrome Mobile Safari/537.36';
    }
    if (Platform.isIOS) {
      return 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
    }
    if (Platform.isMacOS) {
      return 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) $chrome Safari/537.36';
    }
    if (Platform.isWindows) {
      return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) $chrome Safari/537.36';
    }
    return 'Mozilla/5.0 (X11; Linux x86_64) $chrome Safari/537.36';
  }

  /// Read from the live page rather than assumed — the clearance is bound to
  /// the exact User-Agent that earned it.
  String get userAgent => _uaFromWebView ?? defaultUserAgent;

  String _cookieHeader = '';

  /// For the requests that must leave the WebView — images and video files.
  ///
  /// The image host (`i.animepahe.*`) sits behind Cloudflare too and answers
  /// 403 to a request carrying only a Referer, so the clearance cookie has to
  /// travel with these as well.
  Map<String, String> get dioHeaders => {
        'User-Agent': userAgent,
        'Referer': DomainResolver.referer,
        'Accept-Language': 'en-US,en;q=0.9',
        if (_cookieHeader.isNotEmpty) 'Cookie': _cookieHeader,
      };

  Future<void> attach(InAppWebViewController c) async {
    _controller = c;
    _uaFromWebView = await _readUserAgent(c);
    await _captureCookies();
    _ready = true;
  }

  /// Snapshots the cleared cookies for use outside the WebView.
  Future<void> _captureCookies() async {
    try {
      final jar = CookieManager.instance();
      final cookies = await jar.getCookies(url: WebUri(DomainResolver.base));
      _cookieHeader =
          cookies.map((c) => '${c.name}=${c.value}').join('; ');
    } catch (_) {
      _cookieHeader = '';
    }
  }

  Future<String?> _readUserAgent(InAppWebViewController c) async {
    try {
      final ua = await c.evaluateJavascript(source: 'navigator.userAgent');
      final s = ua?.toString();
      return (s == null || s.isEmpty) ? null : s;
    } catch (_) {
      return null;
    }
  }

  void invalidate() {
    _ready = false;
    _controller = null;
  }

  /// Fetches [url] from inside the cleared page and returns the body.
  Future<String> fetch(String url, {bool asJson = true}) async {
    final c = _controller;
    if (c == null) throw StateError('Cloudflare session is not ready yet');

    final result = await c.callAsyncJavaScript(
      functionBody: r'''
        const res = await fetch(url, {
          credentials: 'include',
          headers: asJson
            ? { 'Accept': 'application/json, text/javascript, */*; q=0.01',
                'X-Requested-With': 'XMLHttpRequest' }
            : { 'Accept': 'text/html,application/xhtml+xml' },
        });
        if (!res.ok) throw new Error('HTTP ' + res.status);
        return await res.text();
      ''',
      arguments: {'url': url, 'asJson': asJson},
    );

    if (result == null) throw Exception('No response from WebView');
    if (result.error != null) throw Exception('Request failed: ${result.error}');
    final body = result.value;
    if (body is! String || body.isEmpty) {
      throw Exception('Empty response for $url');
    }
    return body;
  }

  /// Fetches binary content — posters and snapshots — through the cleared page.
  ///
  /// The image host (`i.animepahe.*`) is a different origin from the site and
  /// carries its own Cloudflare protection, so neither a Referer nor the
  /// site's clearance cookie is enough: both return 403. Reading the bytes
  /// from inside the page sidesteps that the same way the API calls do.
  Future<Uint8List> fetchBytes(String url) async {
    // Known limitation: this fails for animepahe's poster host. That host is
    // a separate origin serving no CORS headers, so reading its bytes here
    // raises "TypeError: Failed to fetch", and a plain HTTP request is refused
    // with a Cloudflare 403 since it issues its own clearance. Parking a
    // second WebView on that origin does work around CORS, but running two
    // challenges at once starved the main one and left the app on a loading
    // screen, so posters fall back to a placeholder for now.
    final c = _controller;
    if (c == null) throw StateError('Cloudflare session is not ready yet');

    final result = await c.callAsyncJavaScript(
      functionBody: r'''
        const res = await fetch(url, { credentials: 'include' });
        if (!res.ok) throw new Error('HTTP ' + res.status);
        const blob = await res.blob();
        return await new Promise((resolve, reject) => {
          const reader = new FileReader();
          reader.onloadend = () => {
            const s = String(reader.result);
            resolve(s.slice(s.indexOf(',') + 1));
          };
          reader.onerror = () => reject(new Error('read failed'));
          reader.readAsDataURL(blob);
        });
      ''',
      arguments: {'url': url},
    );

    if (result?.error != null) {
      throw Exception('Image failed: ${result!.error}');
    }
    final b64 = result?.value;
    if (b64 is! String || b64.isEmpty) throw Exception('Empty image $url');
    return base64Decode(b64);
  }
}

enum _GateState { probing, clearing, needsUser }

/// Resolves the live domain, clears Cloudflare, then keeps the cleared WebView
/// mounted off-screen so [CfSession.fetch] can keep using it.
///
/// Most challenges solve themselves. One that still needs a tap after
/// [_autoTimeout] is shown inside app chrome, rather than leaving the app on a
/// splash screen forever.
class CfGatewayWidget extends StatefulWidget {
  final VoidCallback onReady;
  final Widget child;

  const CfGatewayWidget({super.key, required this.onReady, required this.child});

  @override
  State<CfGatewayWidget> createState() => _CfGatewayWidgetState();
}

class _CfGatewayWidgetState extends State<CfGatewayWidget> {
  /// Cloudflare's managed challenge often spends 15-20s on "Verifying…" before
  /// clearing itself. A shorter wait pushes the interactive frame in front of a
  /// check that was about to pass on its own.
  static const _autoTimeout = Duration(seconds: 35);

  /// Pins the WebView's element identity so a rebuild cannot recreate it.
  final _webViewKey = GlobalKey();

  /// Captured at creation. The view is built before the domain is known, so
  /// the first navigation has to be issued through the controller rather than
  /// initialUrlRequest, which is only read when the view is created.
  InAppWebViewController? _gateController;
  bool _navigated = false;

  _GateState _state = _GateState.probing;
  bool _cleared = false;
  Timer? _timer;
  Timer? _poll;
  String? _url;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    await DomainResolver.loadCached();
    await DomainResolver.resolve();
    if (!mounted) return;
    setState(() {
      _url = DomainResolver.base;
      _state = _GateState.clearing;
    });
    _navigateWhenReady();
    _timer = Timer(_autoTimeout, () {
      if (!_cleared && mounted) setState(() => _state = _GateState.needsUser);
    });
  }

  /// Runs on both paths — controller ready and URL ready — because either can
  /// land first, and navigation needs both.
  Future<void> _navigateWhenReady() async {
    final c = _gateController;
    final url = _url;
    if (c == null || url == null || _navigated) return;
    _navigated = true;
    debugPrint('CFGATE: navigating to $url');
    await c.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  Future<void> _onLoadStop(InAppWebViewController c, WebUri? url) async {
    debugPrint('CFGATE: onLoadStop url=$url');
    if (_cleared) return;

    final landed = url?.host;
    if (landed != null) await DomainResolver.adoptFromWebView(landed);

    await _reportStorageCapability(c);
    _startWatching(c);
  }

  /// Cloudflare's challenge has to persist state to finish. If the sandbox is
  /// blocking cookies or localStorage it can never complete, which is
  /// indistinguishable from a stalled challenge.
  Future<void> _reportStorageCapability(InAppWebViewController c) async {
    try {
      final r = await c.evaluateJavascript(source: '''
        (function () {
          var out = [];
          try {
            localStorage.setItem('__pc', '1');
            out.push('ls=' + (localStorage.getItem('__pc') === '1'));
          } catch (e) { out.push('ls=throw'); }
          try {
            document.cookie = '__pc=1; path=/';
            out.push('ck=' + (document.cookie.indexOf('__pc=1') >= 0));
          } catch (e) { out.push('ck=throw'); }
          out.push('cookieEnabled=' + navigator.cookieEnabled);
          out.push('ua=' + navigator.userAgent.slice(0, 90));
          return out.join(' | ');
        })()
      ''');
      debugPrint('CFGATE: storage -> $r');
    } catch (e) {
      debugPrint('CFGATE: storage check threw $e');
    }
  }

  /// Polls until Cloudflare lets us through.
  ///
  /// Checking once on onLoadStop was the central bug: the "Just a moment"
  /// interstitial finishes its work several seconds later, in JavaScript, so
  /// a single immediate probe always saw 403. Android happened to work only
  /// because its challenge ended in a page navigation, which fired a second
  /// onLoadStop; macOS clears in place, so nothing ever re-checked.
  void _startWatching(InAppWebViewController c) {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 2), (t) async {
      if (!mounted || _cleared) {
        t.cancel();
        return;
      }

      if (await _looksCleared(c)) {
        t.cancel();
        _cleared = true;
        _timer?.cancel();
        await CfSession().attach(c);
        if (mounted) {
          setState(() {});
          widget.onReady();
        }
        return;
      }

      // Turnstile injects its widget after the page settles, so this only
      // becomes true partway through — hence checking on every tick.
      if (await _hasInteractiveChallenge(c) &&
          _state != _GateState.needsUser &&
          mounted) {
        _timer?.cancel();
        setState(() => _state = _GateState.needsUser);
      }
    });
  }

  /// True when the page is showing something a person has to click.
  ///
  /// Uses evaluateJavascript rather than callAsyncJavaScript, which is the
  /// better supported of the two across platforms.
  Future<bool> _hasInteractiveChallenge(InAppWebViewController c) async {
    try {
      final r = await c.evaluateJavascript(source: '''
        (function () {
          var frame = document.querySelector(
            'iframe[src*="challenges.cloudflare.com"]');
          var box = document.querySelector('input[type=checkbox]');
          return (frame || box) ? '1' : '0';
        })()
      ''');
      final found = r?.toString().trim() == '1';
      debugPrint('CFGATE: interactive challenge present=$found');
      return found;
    } catch (e) {
      debugPrint('CFGATE: interactive check threw $e');
      return false;
    }
  }

  /// Confirms clearance by calling the API. Nothing else is consulted.
  ///
  /// An earlier version rejected the page first if its HTML contained a
  /// Cloudflare marker, which never worked: Cloudflare injects a
  /// `/cdn-cgi/challenge-platform/...` script into ordinary protected pages,
  /// not only interstitials. That matched on a perfectly cleared page, so this
  /// returned false forever and the probe below never ran.
  ///
  /// The probe is the only thing that actually matters — the API answers with
  /// JSON exactly when Cloudflare has let us through.
  Future<bool> _looksCleared(InAppWebViewController c) async {
    try {
      final probe = await c.callAsyncJavaScript(functionBody: r'''
        const r = await fetch('/api?m=airing&page=1', {
          credentials: 'include',
          headers: { 'Accept': 'application/json',
                     'X-Requested-With': 'XMLHttpRequest' },
        });
        if (!r.ok) return 'status:' + r.status;
        const t = (await r.text()).trim();
        return t.startsWith('{') || t.startsWith('[') ? 'ok' : 'notjson';
      ''');
      final value = probe?.value;
      debugPrint('CFGATE: probe=$value error=${probe?.error}');
      return value == 'ok';
    } catch (e) {
      debugPrint('CFGATE: probe threw $e');
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = CfSession().isReady;
    final interactive = _state == _GateState.needsUser && !ready;
    const headerHeight = 96.0;

    // Child order is fixed so the WebView keeps one identity and one set of
    // ancestors for the whole session. Re-parenting it made Flutter dispose
    // the element, taking the cleared session with it.
    return Stack(
      children: [
        // Full size from the very first frame, never 1x1. Cloudflare's
        // Turnstile runs its own checks on the rendering environment, and a
        // one-pixel viewport reads as a bot, so the challenge would loop
        // instead of completing. It stays full size and simply gets covered.
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !interactive,
            child: InAppWebView(
              key: _webViewKey,
              onWebViewCreated: (c) {
                _gateController = c;
                _navigateWhenReady();
              },
              initialSettings: InAppWebViewSettings(
                userAgent: CfSession.webViewUserAgent,
                // WKWebView's own UA stops at "(KHTML, like Gecko)" with no
                // Version/Safari suffix, which is the standard embedded-
                // WebView fingerprint; Cloudflare rejects it as a non-browser
                // client and its challenge never completes. This appends the
                // suffix a real Safari sends, which is truthful here since the
                // engine genuinely is WebKit.
                applicationNameForUserAgent: 'Version/17.4 Safari/605.1.15',
                javaScriptEnabled: true,
                domStorageEnabled: true,
                databaseEnabled: true,
                thirdPartyCookiesEnabled: true,
                clearCache: false,
                incognito: false,
              ),
              onLoadStop: _onLoadStop,
            ),
          ),
        ),

        // Covers the WebView until a human is actually needed.
        if (!interactive)
          Positioned.fill(
            child: ready ? widget.child : _GateSplash(message: _splashMessage),
          ),

        if (interactive)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: headerHeight,
            child: _ChallengeHeader(),
          ),
      ],
    );
  }

  String get _splashMessage => switch (_state) {
        _GateState.probing => 'Finding a live server…',
        _GateState.clearing => 'Getting things ready…',
        _GateState.needsUser => 'Waiting for the check…',
      };
}

/// Sits above the challenge WebView as a sibling, so it can appear and
/// disappear without ever re-parenting the WebView.
class _ChallengeHeader extends StatelessWidget {
  const _ChallengeHeader();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFFFCFBF9),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'One quick check',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF3A342F),
                ),
              ),
              SizedBox(height: 2),
              Text(
                'Tap the box below once to confirm you are human.',
                style: TextStyle(fontSize: 12, color: Color(0xFF7A716A)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GateSplash extends StatelessWidget {
  final String message;
  const _GateSplash({required this.message});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFCFBF9),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Pahe Cat',
              style: TextStyle(
                fontSize: 38,
                fontWeight: FontWeight.w800,
                color: Color(0xFF3A342F),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              style: const TextStyle(fontSize: 13, color: Color(0xFF7A716A)),
            ),
            const SizedBox(height: 26),
            const SizedBox(
              width: 150,
              child: LinearProgressIndicator(
                backgroundColor: Color(0xFFE8E3DC),
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF6B615A)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
