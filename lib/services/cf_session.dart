import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'domain_resolver.dart';

/// Holds the Cloudflare clearance cookies for the current animepahe domain.
class CfSession {
  static final CfSession _instance = CfSession._();
  CfSession._();
  factory CfSession() => _instance;

  Map<String, String> _cookies = {};
  bool _ready = false;
  String? _uaOverride;

  bool get isReady => _ready;

  /// A UA matching the host platform. An Android UA sent from a desktop build
  /// is a fingerprint mismatch that Cloudflare scores against us.
  String get userAgent {
    if (_uaOverride != null) return _uaOverride!;
    const chrome =
        'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0';
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

  Map<String, String> get dioHeaders => {
        'User-Agent': userAgent,
        'Referer': DomainResolver.referer,
        'Origin': DomainResolver.origin,
        'X-Requested-With': 'XMLHttpRequest',
        if (_cookies.isNotEmpty)
          'Cookie':
              _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
      };

  void onCookiesReady(Map<String, String> cookies, {String? ua}) {
    _cookies = Map.from(cookies);
    if (ua != null && ua.isNotEmpty) _uaOverride = ua;
    _ready = true;
  }

  /// Call when requests start coming back 403 — forces a fresh handshake.
  void invalidate() {
    _cookies = {};
    _ready = false;
  }
}

enum _GateState { probing, clearing, needsUser, failed }

/// Resolves the live domain, then clears Cloudflare in a WebView.
///
/// The WebView stays off-screen while the challenge solves itself. If it is
/// still not cleared after [_autoTimeout] the challenge is interactive, so the
/// WebView is shown full-screen for the user to solve, rather than leaving the
/// app stuck on a splash screen forever.
class CfGatewayWidget extends StatefulWidget {
  final VoidCallback onReady;
  final Widget child;

  const CfGatewayWidget({super.key, required this.onReady, required this.child});

  @override
  State<CfGatewayWidget> createState() => _CfGatewayWidgetState();
}

class _CfGatewayWidgetState extends State<CfGatewayWidget> {
  static const _autoTimeout = Duration(seconds: 12);

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
    if (!CfSession().isReady) {
      await DomainResolver.resolve();
    }
    if (!mounted) return;
    setState(() {
      _url = DomainResolver.base;
      _state = _GateState.clearing;
    });
    _timer = Timer(_autoTimeout, () {
      if (!_cleared && mounted) {
        setState(() => _state = _GateState.needsUser);
      }
    });
  }

  Future<void> _onLoadStop(InAppWebViewController c, WebUri? url) async {
    if (_cleared) return;

    // A redirect to a different animepahe host means the domain moved.
    final landed = url?.host;
    if (landed != null) await DomainResolver.adoptFromWebView(landed);

    if (!await _looksCleared(c)) return;

    _cleared = true;
    _timer?.cancel();

    final jar = CookieManager.instance();
    final raw = await jar.getCookies(url: WebUri(DomainResolver.base));
    CfSession().onCookiesReady(
      {for (final ck in raw) ck.name: ck.value.toString()},
    );
    if (mounted) widget.onReady();
  }

  /// Cloudflare interstitials carry a challenge marker and no site content.
  /// Checking for a real API surface is more reliable than string-matching the
  /// page, since challenge pages also contain the site name in the title.
  Future<bool> _looksCleared(InAppWebViewController c) async {
    final html = (await c.getHtml() ?? '').toLowerCase();
    if (html.isEmpty) return false;
    const markers = [
      'cf-browser-verification',
      'challenge-platform',
      'cf-challenge',
      'just a moment',
      'checking your browser',
      'turnstile',
    ];
    if (markers.any(html.contains)) return false;
    // The real site ships a nav/search shell; a bare CF page does not.
    return html.contains('animepahe') && html.contains('</nav>') ||
        html.contains('id="search"') ||
        html.contains('class="episode');
  }

  @override
  Widget build(BuildContext context) {
    final interactive = _state == _GateState.needsUser;

    return Stack(
      children: [
        if (CfSession().isReady) widget.child else _Splash(state: _state),
        if (!CfSession().isReady && _url != null)
          // Off-screen until we know a human is needed, then full-screen.
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !interactive,
              child: Opacity(
                opacity: interactive ? 1 : 0,
                child: InAppWebView(
                  initialUrlRequest: URLRequest(url: WebUri(_url!)),
                  initialSettings: InAppWebViewSettings(
                    userAgent: CfSession().userAgent,
                    javaScriptEnabled: true,
                    domStorageEnabled: true,
                    clearCache: false,
                    transparentBackground: true,
                  ),
                  onLoadStop: _onLoadStop,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _Splash extends StatelessWidget {
  final _GateState state;
  const _Splash({required this.state});

  String get _message => switch (state) {
        _GateState.probing => 'Finding a live server…',
        _GateState.clearing => 'Verifying connection…',
        _GateState.needsUser => 'Please complete the check above',
        _GateState.failed => 'Could not reach animepahe',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A14),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ShaderMask(
              shaderCallback: (b) => const LinearGradient(
                colors: [Color(0xFF9B59FF), Color(0xFFFF6B9D)],
              ).createShader(b),
              child: const Text(
                'Pahe Boy',
                style: TextStyle(
                  fontSize: 42,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                  letterSpacing: -1,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _message,
              style: const TextStyle(
                color: Color(0xFF6B6486),
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 28),
            const SizedBox(
              width: 160,
              child: LinearProgressIndicator(
                backgroundColor: Color(0xFF2A2A40),
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF9B59FF)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
