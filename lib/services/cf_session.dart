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

  _GateState _state = _GateState.probing;
  bool _cleared = false;
  Timer? _timer;
  String? _url;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
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
    _timer = Timer(_autoTimeout, () {
      if (!_cleared && mounted) setState(() => _state = _GateState.needsUser);
    });
  }

  Future<void> _onLoadStop(InAppWebViewController c, WebUri? url) async {
    if (_cleared) return;

    final landed = url?.host;
    if (landed != null) await DomainResolver.adoptFromWebView(landed);
    if (!await _looksCleared(c)) return;

    _cleared = true;
    _timer?.cancel();
    await CfSession().attach(c);
    // The clearance cookie persists in the platform WebView's own cookie
    // store, so a later launch loads straight through without a challenge.
    if (mounted) {
      setState(() {});
      widget.onReady();
    }
  }

  /// Confirms clearance by calling the API rather than matching page markup.
  ///
  /// Looking for strings like "latest release" meant a markup change left the
  /// app stuck behind a challenge it had already passed. The API only returns
  /// JSON once Cloudflare has let us through, which makes this a direct test
  /// of the thing we actually need.
  Future<bool> _looksCleared(InAppWebViewController c) async {
    final html = (await c.getHtml() ?? '').toLowerCase();
    if (html.isEmpty) return false;

    const challengeMarkers = [
      'cf-browser-verification',
      'challenge-platform',
      'just a moment',
      'checking your browser',
      'cf-challenge',
    ];
    if (challengeMarkers.any(html.contains)) return false;

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
      return probe?.value == 'ok';
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = CfSession().isReady;
    final interactive = _state == _GateState.needsUser && !ready;
    final size = MediaQuery.of(context).size;

    return Stack(
      children: [
        if (ready) widget.child else _GateSplash(message: _splashMessage),

        // Stays mounted after clearing: disposing it would take the cleared
        // session with it. Parked at 1x1 off-screen once off screen is fine.
        if (_url != null)
          Positioned(
            left: interactive ? 0 : -10,
            top: interactive ? 0 : -10,
            width: interactive ? size.width : 1,
            height: interactive ? size.height : 1,
            child: _ChallengeFrame(
              visible: interactive,
              child: InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(_url!)),
                initialSettings: InAppWebViewSettings(
                  userAgent: CfSession.defaultUserAgent,
                  javaScriptEnabled: true,
                  domStorageEnabled: true,
                  databaseEnabled: true,
                  thirdPartyCookiesEnabled: true,
                  clearCache: false,
                ),
                onLoadStop: _onLoadStop,
              ),
            ),
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

/// Wraps the challenge in app chrome, so a required tap looks deliberate
/// instead of a bare browser dumped over the UI.
class _ChallengeFrame extends StatelessWidget {
  final bool visible;
  final Widget child;

  const _ChallengeFrame({required this.visible, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!visible) return child;
    return ColoredBox(
      color: const Color(0xFFFCFBF9),
      child: SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 20, 24, 4),
              child: Text(
                'One quick check',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF3A342F),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Text(
                'Tap the box below to confirm you are human. '
                'Usually only needed once.',
                style: TextStyle(fontSize: 13, color: Color(0xFF7A716A)),
              ),
            ),
            Expanded(child: child),
          ],
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
