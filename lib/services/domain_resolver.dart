import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// AnimePahe rotates domains (.ru → .com → .org → .pw → …).
///
/// Dead domains 301 to the live one, so probing the known list and taking a
/// majority vote on redirect targets finds the current domain even when it uses
/// a TLD not in [_candidates].
///
/// Cloudflare answers non-browser requests with 403/503. That means "alive
/// behind CF", NOT "dead" — a naive 200-only check rejects every domain.
class DomainResolver {
  // .pw is canonical as of 2026-09; .com/.org redirect to it. Verified live
  // hosts sit behind Cloudflare. .ru and .su are squatted, .net is parked —
  // kept out of the list, and _isParked() rejects them if they ever appear as
  // a redirect target.
  static const _candidates = [
    'animepahe.pw',
    'animepahe.com',
    'animepahe.org',
    'animepahe.ru',
  ];

  static const _prefsKey = 'resolved_domain';
  static const _prefsKeyAt = 'resolved_domain_at';
  static const _staleAfter = Duration(hours: 12);

  static String? _host;

  static String get host => _host ?? _candidates.first;
  static String get base => 'https://$host';
  static String get origin => base;
  static String get referer => '$base/';

  static final _probe = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 6),
    receiveTimeout: const Duration(seconds: 6),
    followRedirects: true,
    maxRedirects: 5,
    validateStatus: (_) => true,
    headers: {
      'User-Agent':
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
    },
  ));

  /// Loads the cached domain. Call once at startup before any API use.
  static Future<void> loadCached() async {
    final p = await SharedPreferences.getInstance();
    final cached = p.getString(_prefsKey);
    final at = p.getInt(_prefsKeyAt) ?? 0;
    if (cached == null) return;
    _host = cached;
    final age = DateTime.now().millisecondsSinceEpoch - at;
    if (age > _staleAfter.inMilliseconds) {
      resolve();  // refresh in background, keep serving the cached host
    }
  }

  /// Probes every candidate in parallel and adopts the winner.
  /// Returns the resolved host. Falls back to the cached/default host.
  static Future<String> resolve() async {
    final results = await Future.wait(_candidates.map(_probeOne));
    final alive = results.whereType<_Probe>().toList();
    if (alive.isEmpty) return host;

    // Dead domains redirect to the live one — majority vote on where they land
    // discovers the current domain even on an unknown TLD.
    final votes = <String, int>{};
    for (final r in alive) {
      votes[r.finalHost] = (votes[r.finalHost] ?? 0) + 1;
    }
    final winner = votes.entries.reduce((a, b) => a.value >= b.value ? a : b).key;

    await _save(winner);
    return winner;
  }

  /// Adopts [host] when the WebView (which executes CF's JS) lands somewhere
  /// other than where we sent it — the most trustworthy signal available.
  static Future<void> adoptFromWebView(String landedHost) async {
    if (!_looksLikeAnimePahe(landedHost) || landedHost == _host) return;
    await _save(landedHost);
  }

  static Future<void> _save(String h) async {
    _host = h;
    final p = await SharedPreferences.getInstance();
    await p.setString(_prefsKey, h);
    await p.setInt(_prefsKeyAt, DateTime.now().millisecondsSinceEpoch);
  }

  static Future<_Probe?> _probeOne(String candidate) async {
    try {
      final r = await _probe.get<String>('https://$candidate/');
      final finalHost = r.realUri.host;
      // A matching hostname proves nothing — expired animepahe domains get
      // resold and serve parking pages under the same name.
      if (!_looksLikeAnimePahe(finalHost)) return null;
      if (![200, 403, 503].contains(r.statusCode)) return null;

      final body = (r.data ?? '').toLowerCase();
      if (_isParked(body)) return null;
      if (!_isCloudflare(body) && !_isRealSite(body)) return null;

      return _Probe(candidate, finalHost);
    } catch (_) {
      return null; // DNS failure, refused, timeout → dead
    }
  }

  /// Rewrites an animepahe asset URL onto the live domain.
  ///
  /// The API returns posters and snapshots on whatever host it was written
  /// against — currently `i.animepahe.ru`, which no longer resolves at all
  /// while the site itself runs on `.pw`. Without this every image fails to
  /// load. Only the TLD is swapped, so the image subdomain is preserved.
  static String rewriteAsset(String url) {
    if (url.isEmpty) return url;
    final liveTld = host.split('.').last;
    return url.replaceFirstMapped(
      RegExp(r'^(https?://[a-z0-9.\-]*animepahe)\.[a-z]{2,6}(?=/|$)',
          caseSensitive: false),
      (m) => '${m.group(1)}.$liveTld',
    );
  }

  static bool _looksLikeAnimePahe(String h) =>
      h == 'animepahe.su' // known squatter, never adopt
          ? false
          : h.startsWith('animepahe.') || h.startsWith('www.animepahe.');

  static bool _isParked(String body) => const [
        'domain is for sale',
        'this domain is for sale',
        'buy this domain',
        'related searches',
        'domain parking',
        'contact the owner',
      ].any(body.contains);

  /// The real host answers non-browser clients with a Cloudflare interstitial,
  /// so a challenge page is positive evidence the domain is live.
  static bool _isCloudflare(String body) =>
      body.contains('just a moment') ||
      body.contains('challenge-platform') ||
      body.contains('cf-browser-verification') ||
      (body.contains('cloudflare') && body.contains('enable javascript'));

  static bool _isRealSite(String body) =>
      body.contains('latest release') ||
      body.contains('/anime/') ||
      body.contains('class="episode');
}

class _Probe {
  final String probedHost;
  final String finalHost;
  const _Probe(this.probedHost, this.finalHost);
}
