import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'cf_session.dart';
import 'domain_resolver.dart';

/// One-shot structural dump of a live play page.
///
/// The parser in [AnimePaheApi.parsePlayPage] was originally written without
/// ever seeing this markup, which cost several rounds of guessing. This walks
/// the API to a real play page and prints the parts a parser depends on, so
/// selectors can be written against what the site actually serves.
///
/// Enabled per-run, never in a shipped build:
///   flutter run --dart-define=PAHE_DIAG=true
class Diagnostics {
  static const enabled = bool.fromEnvironment('PAHE_DIAG');

  static Future<void> dumpPlayPage() async {
    if (!enabled) return;
    try {
      final airing = jsonDecode(
          await CfSession().fetch('${DomainResolver.base}/api?m=airing&page=1'));
      final first = (airing['data'] as List).first as Map<String, dynamic>;
      final animeSession = first['anime_session'];
      _log('anime -> ${first['anime_title']} ($animeSession)');

      final release = jsonDecode(await CfSession().fetch(
          '${DomainResolver.base}/api?m=release&id=$animeSession'
          '&sort=episode_asc&page=1'));
      final ep = (release['data'] as List).first as Map<String, dynamic>;
      final playUrl =
          '${DomainResolver.base}/play/$animeSession/${ep['session']}';
      _log('play -> $playUrl');

      final html = await CfSession().fetch(playUrl, asJson: false);
      _log('html length ${html.length}');

      // Everything a source parser could reasonably key off.
      _dumpAll(html, r'<div[^>]*id="pickDownload"[^>]*>[\s\S]{0,2000}?</div>',
          'download menu');
      _dumpAll(html, r'<button[^>]{0,400}>[\s\S]{0,120}?</button>', 'button');
      _dumpAll(html, r'<a[^>]{0,400}(?:data-src|/e/|pahe\.win)[^>]{0,400}>'
          r'[\s\S]{0,120}?</a>', 'anchor');
      _dumpAll(html, r'data-[a-z-]+="[^"]{0,120}"', 'data attribute');
      _dumpAll(html, r'https?://[^\s"\x27<>]{0,120}', 'url');
    } catch (e) {
      _log('failed: $e');
    }
  }

  static void _dumpAll(String html, String pattern, String label,
      {int take = 12}) {
    final matches =
        RegExp(pattern, caseSensitive: false).allMatches(html).take(take);
    var n = 0;
    for (final m in matches) {
      final text = m.group(0)!.replaceAll(RegExp(r'\s+'), ' ').trim();
      _log('$label[${n++}]: ${text.length > 300 ? text.substring(0, 300) : text}');
    }
    if (n == 0) _log('$label: NONE');
  }

  static void _log(String s) => debugPrint('DIAG: $s');
}
