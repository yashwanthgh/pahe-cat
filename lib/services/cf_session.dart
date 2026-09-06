import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
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

  /// Headers for fetching a file outside the WebView.
  ///
  /// [dioHeaders] carries animepahe's referer and cookies, which is wrong for
  /// a media file: those are served from kwik's own CDN, and it answered 403
  /// to a request presenting another site's credentials. The cookies for the
  /// hosts actually involved are collected instead, and the referer is the
  /// page the link came from.
  Future<Map<String, String>> fileHeaders(String url,
      {String referer = ''}) async {
    final cookies = <String>[];
    final seen = <String>{};
    try {
      final jar = CookieManager.instance();
      for (final origin in [url, referer, 'https://kwik.cx/']) {
        if (origin.isEmpty) continue;
        try {
          for (final c in await jar.getCookies(url: WebUri(origin))) {
            if (seen.add(c.name)) cookies.add('${c.name}=${c.value}');
          }
        } catch (_) {
          // A host with no cookies is not a problem.
        }
      }
    } catch (_) {
      // No cookie manager — send what we can.
    }

    return {
      'User-Agent': userAgent,
      'Accept': '*/*',
      'Accept-Language': 'en-US,en;q=0.9',
      if (referer.isNotEmpty) 'Referer': referer,
      if (cookies.isNotEmpty) 'Cookie': cookies.join('; '),
    };
  }

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
      _cookieHeader = cookies.map((c) => '${c.name}=${c.value}').join('; ');
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
    if (result.error != null)
      throw Exception('Request failed: ${result.error}');
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

/// Hides a page's own content from view without hiding the WebView.
///
/// The distinction matters. Painting a Flutter overlay on top of the WebView
/// is what broke Cloudflare on macOS: WebKit stops doing rendering work for a
/// view it believes is covered, so the challenge never finished its
/// JavaScript. This puts the cover *inside the page* instead — a fixed div
/// over the document — so the WebView stays fully visible to the OS and keeps
/// running at full speed, while animepahe's own markup stays out of sight.
///
/// The challenge is then lifted back above the cover by raising it and each of
/// its ancestors, so it is still visible and clickable. `pointer-events: none`
/// on the cover means taps reach the page regardless.
const String kPageShadeScript = r'''
(function () {
  var BG = '#FCFBF9';
  var CSS =
    'html,body{background:' + BG + ' !important}' +
    '#pc-shade{position:fixed;top:0;left:0;right:0;bottom:0;background:' + BG +
    ';z-index:2147483000;pointer-events:none}';

  function style() {
    if (document.getElementById('pc-style')) return;
    var s = document.createElement('style');
    s.id = 'pc-style';
    s.textContent = CSS;
    (document.head || document.documentElement).appendChild(s);
  }

  function shade() {
    if (!document.body || document.getElementById('pc-shade')) return;
    var d = document.createElement('div');
    d.id = 'pc-shade';
    document.body.appendChild(d);
  }

  // Raise the challenge widget above the cover. Each ancestor needs its own
  // stacking context, otherwise a z-index further down is clamped by a parent.
  var lifted = [];

  function lift() {
    // The interstitial builds the widget in stages: #challenge-stage and
    // #turnstile-wrapper exist before the cross-origin iframe inside them
    // does. Matching only the iframe meant the widget was covered for as long
    // as it took to arrive, and stayed covered whenever it never arrived under
    // that exact selector.
    var f = document.querySelector(
      'iframe[src*="challenges.cloudflare.com"], .cf-turnstile,' +
      ' #turnstile-wrapper, #challenge-stage');
    if (!f) return;

    // Put it in the middle of our panel. Left in the page's own flow it sat in
    // the top-left corner, against a heading and body text that the shade has
    // hidden, so it read as a stray box rather than the thing to click.
    f.style.setProperty('position', 'fixed', 'important');
    f.style.setProperty('top', '50%', 'important');
    f.style.setProperty('left', '50%', 'important');
    f.style.setProperty('transform', 'translate(-50%, -50%)', 'important');
    f.style.setProperty('margin', '0', 'important');
    if (lifted.indexOf(f) < 0) lifted.push(f);

    // Starts at the parent, not at f: f is fixed now, and the ancestor walk
    // below forces position:relative, which would undo that immediately.
    for (var el = f.parentElement;
         el && el !== document.body;
         el = el.parentElement) {
      el.style.setProperty('position', 'relative', 'important');
      el.style.setProperty('z-index', '2147483600', 'important');
      el.style.setProperty('background', BG, 'important');
      el.style.setProperty('visibility', 'visible', 'important');
      if (lifted.indexOf(el) < 0) lifted.push(el);
    }
  }

  // Put the page back exactly as it was. Forcing position:relative on the
  // challenge's ancestors is what a cover needs, but leaving it in place
  // pulled the widget out of the middle of the page and into the corner once
  // the cover was gone.
  function unlift() {
    for (var i = 0; i < lifted.length; i++) {
      var el = lifted[i];
      el.style.removeProperty('position');
      el.style.removeProperty('z-index');
      el.style.removeProperty('background');
      el.style.removeProperty('visibility');
      // Set only on the widget itself by lift(), to centre it.
      el.style.removeProperty('top');
      el.style.removeProperty('left');
      el.style.removeProperty('transform');
      el.style.removeProperty('margin');
    }
    lifted = [];
    var st = document.getElementById('pc-style');
    if (st) st.remove();
  }

  function apply() {
    // A page that turns out to need a person seen it — a Cloudflare check, say
    // — asks for the cover to come off, since the widget has to be visible to
    // be ticked.
    if (window.__pcNoShade) {
      var existing = document.getElementById('pc-shade');
      if (existing) existing.remove();
      unlift();
      return;
    }
    style(); shade(); lift();
  }

  // Exposed so the gate can re-run it the moment clearance is confirmed. The
  // MutationObserver below only fires on a change, and a page that is already
  // finished loading does not make one.
  window.__pcApplyShade = apply;

  apply();
  document.addEventListener('DOMContentLoaded', apply);
  try {
    new MutationObserver(apply)
      .observe(document.documentElement, { childList: true, subtree: true });
  } catch (e) {}
})();
''';

/// Applied at document start so the page is never shown before it is covered.
UnmodifiableListView<UserScript> get kShadeUserScripts => UnmodifiableListView([
      UserScript(
        source: kPageShadeScript,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      ),
    ]);

/// The gate's scripts: the shade, preceded by a flag that holds it off until
/// we are actually through Cloudflare.
///
/// The rule is deliberately about clearance rather than about recognising a
/// challenge. Trying to spot the challenge by its markup does not hold up —
/// `#challenge-form` and `#challenge-running` were absent from the very page
/// titled "Just a moment...", so the shade stayed up over the widget and left
/// a blank panel with nothing to tick. Whether we are through, on the other
/// hand, is already known for certain, because the API probe settles it.
///
/// So: not through yet, no shade, and whatever Cloudflare puts up is visible
/// and clickable. Through, shade on, and animepahe's own page is hidden behind
/// our UI — which is the only page anyone wanted hidden.
UnmodifiableListView<UserScript> get kGateUserScripts => UnmodifiableListView([
      UserScript(
        source: 'window.__pcNoShade = true;',
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      ),
      ...kShadeUserScripts,
    ]);

enum _Phase { resolving, verifying, cleared }

/// Resolves the live domain, gets past Cloudflare, then keeps the cleared
/// WebView mounted so [CfSession.fetch] can keep using it.
///
/// The verification page is shown plainly instead of being hidden behind a
/// splash. An earlier version tried to detect whether a person was needed and
/// only then revealed the WebView, but that detection cannot be made reliable:
/// Cloudflare's widget lives in a cross-origin iframe, which `querySelector`
/// is not permitted to look inside. So the app sat behind a cover while a
/// check waited on a click it never received. Showing the real page removes
/// the need to detect anything — whatever Cloudflare puts up is visible, and
/// can be acted on.
///
/// Mirrors are rotated as well. A host that will not clear is often replaced
/// by one that clears with no interaction at all, so waiting on a single
/// domain forever gives up a free fix.
class CfGatewayWidget extends StatefulWidget {
  final VoidCallback onReady;
  final Widget child;

  const CfGatewayWidget(
      {super.key, required this.onReady, required this.child});

  @override
  State<CfGatewayWidget> createState() => _CfGatewayWidgetState();
}

class _CfGatewayWidgetState extends State<CfGatewayWidget> {
  /// How long one mirror gets before the next is tried.
  ///
  /// A managed challenge often clears itself in about 15s, but one that puts up
  /// a checkbox waits on a person, and 20s was not long enough to read the
  /// screen and click. Rotating mid-challenge is worse than waiting: the next
  /// host starts its own challenge from nothing, so a series of too-short
  /// attempts never finishes anywhere.
  static const _perHostTimeout = Duration(seconds: 60);

  /// The gap between clearance probes.
  ///
  /// This was 1.5s, which meant roughly 40 requests a minute at a host that was
  /// still challenging us — and animepahe answered that with 429. A rate-
  /// limited challenge cannot complete, so the probe was preventing the very
  /// thing it was waiting for. Probes are also skipped entirely while the
  /// document is still a challenge page; see [_check].
  static const _pollInterval = Duration(seconds: 3);

  /// Pins the WebView's element identity. Re-parenting it made Flutter dispose
  /// the element and take the cleared session with it, so its ancestor chain is
  /// built once and never varies.
  final _webViewKey = GlobalKey();

  InAppWebViewController? _controller;

  _Phase _phase = _Phase.resolving;

  /// Mirrors to work through, resolved host first.
  List<String> _order = const [];
  int _hostIndex = 0;

  /// Set on the first touch inside the WebView. Rotating mirrors underneath
  /// somebody who is part-way through solving a check would throw away their
  /// progress, so automatic rotation stops once they have engaged with it.
  bool _userInteracted = false;

  /// True once every mirror has been tried, which turns the panel into a
  /// manual one rather than rotating in circles.
  bool _exhausted = false;

  /// Last probe result, shown on screen. Release builds have no console, so
  /// without this a stuck gate is undiagnosable from a user's report.
  String _diag = '';

  Timer? _hostTimer;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _hostTimer?.cancel();
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    await DomainResolver.loadCached();
    final resolved = await DomainResolver.resolve();
    if (!mounted) return;
    _order = [
      resolved,
      ...DomainResolver.candidates.where((h) => h != resolved),
    ];
    _useHost(0);
  }

  void _useHost(int index) {
    _hostIndex = index;
    DomainResolver.use(_order[index]);
    if (!mounted) return;
    setState(() {
      _phase = _Phase.verifying;
      _diag = '';
    });
    _navigate();
  }

  /// Navigation is imperative because the WebView is built before the domain
  /// is known, and `initialUrlRequest` is only read when the view is created.
  /// Either the controller or the host can arrive first, so both paths call
  /// this and it does nothing until both are present.
  Future<void> _navigate() async {
    final c = _controller;
    if (c == null || _phase != _Phase.verifying) return;
    final url = DomainResolver.base;
    debugPrint('CFGATE: -> $url (${_hostIndex + 1}/${_order.length})');
    _armHostTimer();
    _startPolling();
    await c.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  void _armHostTimer() {
    _hostTimer?.cancel();
    if (_exhausted) return;
    _hostTimer = Timer(_perHostTimeout, _rotate);
  }

  /// Moves to the next mirror. [manual] wraps around and ignores the
  /// interaction guard, since an explicit tap on "Try another server" is a
  /// request to move regardless.
  void _rotate({bool manual = false}) {
    if (!mounted || _phase == _Phase.cleared) return;
    if (!manual && _userInteracted) return;

    final next = _hostIndex + 1;
    if (next >= _order.length) {
      if (manual) {
        _userInteracted = false;
        _useHost(0);
      } else {
        _hostTimer?.cancel();
        setState(() => _exhausted = true);
      }
      return;
    }
    if (manual) _userInteracted = false;
    _useHost(next);
  }

  Future<void> _onLoadStop(InAppWebViewController c, WebUri? url) async {
    if (_phase == _Phase.cleared) return;
    final landed = url?.host;
    if (landed != null) await DomainResolver.adoptFromWebView(landed);
    // Probe straight away as well as on the timer: a mirror that needs no
    // challenge at all is already cleared by the time it finishes loading, and
    // waiting for the next tick would show it the raw site for no reason.
    await _check();
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(_pollInterval, (_) => _check());
  }

  /// Set once the failure has been explained, so a poll every few seconds does
  /// not repeat the whole ladder.
  bool _explained = false;

  /// Says *why* the readiness probe failed, once, in the debug log.
  ///
  /// The probe is a single request to one API path, so every cause reads the
  /// same from the outside: a challenge that has not been solved, a mirror
  /// that never served the API, and an API path the site has since moved all
  /// arrive here as one unhelpful status. This separates them by asking what
  /// the document actually is and which paths answer, which is the difference
  /// between "wait longer" and "this endpoint no longer exists".
  Future<void> _explainFailure(InAppWebViewController c, String result) async {
    if (_explained) return;
    _explained = true;

    try {
      final probe = await c.callAsyncJavaScript(functionBody: r'''
        const lines = [];
        lines.push('document: ' + location.href);
        lines.push('title: ' + document.title);
        lines.push('html: ' + document.documentElement.innerHTML.length + ' bytes');

        // No request ladder here. Every path was already shown to return the
        // same challenge page, so re-fetching them proves nothing and the
        // requests themselves are what earned us 429s. What is still unknown
        // is what the challenge page is made of — which markers identify it,
        // and whether it contains a widget to click at all.
        lines.push('shaded: ' + !!document.getElementById('pc-shade'));

        const named = document.querySelectorAll('[id]');
        lines.push('ids: ' + Array.from(named)
          .map(function (e) { return e.id; }).slice(0, 25).join(', '));

        lines.push('iframes: ' + Array.from(document.querySelectorAll('iframe'))
          .map(function (f) { return (f.src || '(no src)').slice(0, 60); })
          .join(' | '));

        lines.push('inputs: ' + document.querySelectorAll('input').length +
          ' buttons: ' + document.querySelectorAll('button').length +
          ' forms: ' + document.querySelectorAll('form').length);

        lines.push('body text: ' +
          (document.body ? document.body.innerText : '')
            .replace(/\s+/g, ' ').trim().slice(0, 200));

        return lines.join('\n');
      ''');
      debugPrint('CFGATE DIAGNOSIS (probe was "$result")\n'
          '${probe?.value ?? probe?.error}');
    } catch (e) {
      debugPrint('CFGATE: could not diagnose: $e');
    }
  }

  /// Checks whether Cloudflare has let us through, and if so hands the cleared
  /// controller to [CfSession] and releases the app.
  ///
  /// Clearance is still decided by the API call alone: it answers with JSON
  /// exactly when we are through, and nothing else does. Markers cannot be used
  /// to declare success, because Cloudflare injects its
  /// `/cdn-cgi/challenge-platform/` script into ordinary protected pages too,
  /// so a marker check matches on a perfectly cleared page.
  ///
  /// A challenge is recognised from that same response rather than from the
  /// page, so it costs no extra request: Cloudflare answers a challenged
  /// request with 403 and an HTML body, where the API would answer with JSON.
  /// Reading it off the DOM instead does not work — the interstitial's element
  /// ids are randomised per response (`jddkS1`, `QeINV1`, and so on), so a
  /// selector written against them never matches.
  ///
  /// Knowing that matters because it is the difference between "wait" and
  /// "something is wrong". Treating it as a fault is what led to probing every
  /// 1.5s and earning 429s, and a rate-limited challenge cannot complete.
  Future<void> _check() async {
    if (!mounted || _phase == _Phase.cleared) return;
    final c = _controller;
    if (c == null) return;

    String result;
    try {
      final probe = await c.callAsyncJavaScript(functionBody: r'''
        const r = await fetch('/api?m=airing&page=1', {
          credentials: 'include',
          headers: { 'Accept': 'application/json',
                     'X-Requested-With': 'XMLHttpRequest' },
        });
        const t = (await r.text()).trim();
        if (!r.ok) {
          const html = t.slice(0, 400).toLowerCase().includes('<html');
          return (r.status === 403 && html ? 'challenging:' : 'status:')
            + r.status;
        }
        return t.startsWith('{') || t.startsWith('[') ? 'ok' : 'notjson';
      ''');
      result = probe?.error != null
          ? 'error:${probe!.error}'
          : '${probe?.value ?? 'null'}';
    } catch (e) {
      result = 'threw:$e';
    }

    debugPrint('CFGATE: probe=$result host=${DomainResolver.host}');
    if (!mounted || _phase == _Phase.cleared) return;

    // A challenge in progress is the expected state, not a fault: say so
    // plainly and ask nothing further. Running the diagnosis here would fire
    // six more requests at a host that is already refusing us, which is how
    // the 429s started in the first place.
    // A fetch aborted because the page navigated under it reads as a load
    // failure, and Cloudflare's check navigates the page as part of doing its
    // work — so this is the check running, not a fault. Reported as a fault it
    // put "error:TypeError: Load failed" in front of the user and triggered a
    // diagnosis of a working system.
    final aborted = result.contains('Load failed') ||
        result.contains('Failed to fetch') ||
        result.contains('cancelled');

    if (result.startsWith('challenging') || aborted) {
      setState(() => _diag = 'verifying, this can take a moment');
      return;
    }

    if (result != 'ok') {
      await _explainFailure(c, result);
      if (!mounted || _phase == _Phase.cleared) return;
      setState(() => _diag = result);
      return;
    }

    _phase = _Phase.cleared;
    _poll?.cancel();
    _hostTimer?.cancel();

    // Through Cloudflare, so animepahe's own page is what is on screen now —
    // cover it. Until this point the shade was held off so the challenge
    // stayed visible and clickable.
    try {
      await c.evaluateJavascript(source: '''
        window.__pcNoShade = false;
        if (window.__pcApplyShade) window.__pcApplyShade();
      ''');
    } catch (_) {
      // Cosmetic only: the session is cleared either way.
    }

    await CfSession().attach(c);
    if (!mounted) return;
    setState(() {});
    widget.onReady();
  }

  Future<void> _reload() async {
    _userInteracted = false;
    setState(() => _diag = '');
    _armHostTimer();
    _startPolling();
    await _controller?.loadUrl(
        urlRequest: URLRequest(url: WebUri(DomainResolver.base)));
  }

  Future<void> _openInBrowser() async {
    final uri = Uri.parse(DomainResolver.base);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cleared = _phase == _Phase.cleared && CfSession().isReady;

    // Child order never varies, so the WebView keeps one identity and one set
    // of ancestors for the whole session — including the Listener, which is
    // unconditional for exactly that reason.
    return Stack(
      children: [
        // Full size from the first frame, never one pixel. Turnstile inspects
        // its own rendering environment and treats a tiny viewport as a bot,
        // so the challenge would loop instead of completing. It stays full
        // size and simply gets covered once we are through.
        Positioned.fill(
          child: Listener(
            onPointerDown: (_) => _userInteracted = true,
            child: InAppWebView(
              key: _webViewKey,
              onWebViewCreated: (c) {
                _controller = c;
                _navigate();
              },
              // Shade held off until clearance; see [kGateUserScripts].
              initialUserScripts: kGateUserScripts,
              initialSettings: InAppWebViewSettings(
                userAgent: CfSession.webViewUserAgent,
                // WKWebView's own UA stops at "(KHTML, like Gecko)" with no
                // Version/Safari suffix, which is the standard embedded-
                // WebView fingerprint. This appends what a real Safari sends,
                // which is truthful here since the engine genuinely is WebKit.
                applicationNameForUserAgent: 'Version/17.4 Safari/605.1.15',
                javaScriptEnabled: true,
                domStorageEnabled: true,
                databaseEnabled: true,
                thirdPartyCookiesEnabled: true,
                clearCache: false,
                incognito: false,
                transparentBackground: true,
              ),
              onLoadStop: _onLoadStop,
            ),
          ),
        ),

        if (cleared)
          Positioned.fill(child: widget.child)
        else if (_phase == _Phase.resolving)
          const Positioned.fill(child: _GateSplash())
        else ...[
          // Siblings, never parents, so appearing and disappearing cannot make
          // Flutter rebuild the WebView underneath. They also deliberately do
          // not cover it: the page hides its own content via kPageShadeScript,
          // which leaves the WebView unoccluded and the challenge running.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _VerifyPanel(exhausted: _exhausted),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _VerifyControls(
              host: DomainResolver.host,
              attempt: _hostIndex + 1,
              total: _order.length,
              diag: _diag,
              onReload: _reload,
              onAnotherServer: () => _rotate(manual: true),
              onOpenBrowser: _openInBrowser,
            ),
          ),
        ],
      ],
    );
  }
}

/// The visible "prove you are human" screen.
///
/// Deliberately plain. The page behind it is blanked to the same colour by
/// [kPageShadeScript], so this reads as one screen of the app rather than a
/// banner stuck over somebody else's website — which is what the earlier
/// version looked like.
class _VerifyPanel extends StatelessWidget {
  final bool exhausted;
  const _VerifyPanel({required this.exhausted});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _bg,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 34, 28, 22),
          child: Column(
            children: [
              const Text('\u{1F43E}', style: TextStyle(fontSize: 34)),
              const SizedBox(height: 14),
              Text(
                exhausted ? 'Almost there' : 'Just checking you are human',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: _ink,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                exhausted
                    ? 'Tick the box below if one is showing, or try another '
                        'server.'
                    : 'If a box appears below, tick it once. Usually this '
                        'sorts itself out and disappears on its own.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  color: _muted,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Escape hatches, kept at the bottom so they never sit over the checkbox.
class _VerifyControls extends StatelessWidget {
  final String host;
  final int attempt;
  final int total;
  final String diag;
  final VoidCallback onReload;
  final VoidCallback onAnotherServer;
  final VoidCallback onOpenBrowser;

  const _VerifyControls({
    required this.host,
    required this.attempt,
    required this.total,
    required this.diag,
    required this.onReload,
    required this.onAnotherServer,
    required this.onOpenBrowser,
  });

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _bg,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
          child: Column(
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                alignment: WrapAlignment.center,
                children: [
                  _Chip(label: 'Reload', onTap: onReload),
                  _Chip(label: 'Try another server', onTap: onAnotherServer),
                  _Chip(label: 'Open in browser', onTap: onOpenBrowser),
                ],
              ),
              const SizedBox(height: 8),
              // Shown on screen because release builds have no console: a
              // stuck gate is otherwise undiagnosable from a bug report.
              Text(
                diag.isEmpty
                    ? '$host  ·  server $attempt of $total'
                    : '$host  ·  server $attempt of $total  ·  $diag',
                style: const TextStyle(fontSize: 10, color: _muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const _ink = Color(0xFF3A342F);
const _muted = Color(0xFF7A716A);
const _bg = Color(0xFFFCFBF9);

class _Chip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _Chip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFF2EEE8),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Color(0xFF6B615A),
            ),
          ),
        ),
      ),
    );
  }
}

class _GateSplash extends StatelessWidget {
  const _GateSplash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFFFCFBF9),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('🐾', style: TextStyle(fontSize: 40)),
            SizedBox(height: 10),
            Text(
              'Pahe Cat',
              style: TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w800,
                color: Color(0xFF3A342F),
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Finding a live server…',
              style: TextStyle(fontSize: 13, color: Color(0xFF7A716A)),
            ),
            SizedBox(height: 26),
            SizedBox(
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
