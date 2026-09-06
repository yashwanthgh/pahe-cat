import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Manages Cloudflare clearance cookies for animepahe.
/// Opens an invisible WebView once, waits for CF challenge, then stores cookies.
class CfSession {
  static final CfSession _instance = CfSession._();
  CfSession._();
  factory CfSession() => _instance;

  Map<String, String> _cookies = {};
  bool _ready = false;
  String _userAgent =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  bool get isReady => _ready;
  Map<String, String> get cookies => Map.unmodifiable(_cookies);
  String get userAgent => _userAgent;

  Map<String, String> get dioHeaders => {
        'User-Agent': _userAgent,
        'Referer': 'https://animepahe.ru/',
        'Origin': 'https://animepahe.ru',
        if (_cookies.isNotEmpty)
          'Cookie': _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
      };

  /// Called by [CfGatewayWidget] once challenge passes.
  void onCookiesReady(Map<String, String> cookies, String ua) {
    _cookies = Map.from(cookies);
    if (ua.isNotEmpty) _userAgent = ua;
    _ready = true;
  }

  void invalidate() {
    _cookies = {};
    _ready = false;
  }
}

/// Invisible WebView that loads animepahe, lets CF clear, then fires [onReady].
class CfGatewayWidget extends StatefulWidget {
  final VoidCallback onReady;
  final Widget child;

  const CfGatewayWidget({super.key, required this.onReady, required this.child});

  @override
  State<CfGatewayWidget> createState() => _CfGatewayWidgetState();
}

class _CfGatewayWidgetState extends State<CfGatewayWidget> {
  InAppWebViewController? _wv;
  bool _cleared = false;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (!CfSession().isReady)
          Positioned(
            width: 1, height: 1,
            child: InAppWebView(
              initialUrlRequest: URLRequest(
                url: WebUri('https://animepahe.ru/'),
              ),
              initialSettings: InAppWebViewSettings(
                userAgent: CfSession().userAgent,
                javaScriptEnabled: true,
                clearCache: false,
                domStorageEnabled: true,
              ),
              onWebViewCreated: (c) => _wv = c,
              onLoadStop: (c, url) => _checkCleared(c, url),
            ),
          ),
      ],
    );
  }

  Future<void> _checkCleared(
      InAppWebViewController c, WebUri? url) async {
    if (_cleared) return;
    final html = await c.getHtml() ?? '';
    // CF challenge pages don't contain "animepahe" in the title
    if (html.contains('animepahe') && !html.contains('cf-browser-verification')) {
      _cleared = true;
      final cj = CookieManager.instance();
      final rawCookies = await cj.getCookies(
          url: WebUri('https://animepahe.ru'));
      final map = {for (final c in rawCookies) c.name: c.value.toString()};
      CfSession().onCookiesReady(map, CfSession().userAgent);
      widget.onReady();
    }
  }
}
