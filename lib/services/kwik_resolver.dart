import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'cf_session.dart';
import 'domain_resolver.dart';

/// Resolves a kwik.si/e/<hash> URL to a direct download/stream URL.
/// Uses an invisible WebView to POST the form (required by kwik anti-hotlink).
class KwikResolver {
  /// Returns the direct .mp4 URL, or throws on failure.
  static Future<String> resolve(
    BuildContext context,
    String kwikUrl,
  ) async {
    final completer = Completer<String>();

    final overlay = OverlayEntry(
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
      final result = await completer.future.timeout(const Duration(seconds: 30));
      return result;
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

  @override
  Widget build(BuildContext context) {
    return Positioned(
      width: 1, height: 1, left: -100, top: -100,
      child: InAppWebView(
        initialUrlRequest: URLRequest(
          url: WebUri(widget.kwikUrl),
          headers: {
            'Referer': DomainResolver.referer,
            'User-Agent': CfSession().userAgent,
          },
        ),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          userAgent: CfSession().userAgent,
          allowFileAccessFromFileURLs: false,
        ),
        shouldOverrideUrlLoading: (c, action) async {
          final url = action.request.url?.toString() ?? '';
          // Direct video file → we have it
          if (url.contains('.mp4') || url.contains('/get/') ||
              url.endsWith('.mkv') || url.contains('workers.dev')) {
            widget.onResolved(url);
            return NavigationActionPolicy.CANCEL;
          }
          return NavigationActionPolicy.ALLOW;
        },
        onLoadStop: (c, url) async {
          final html = await c.getHtml() ?? '';
          // Kwik page has a form we need to submit
          if (html.contains('id="dl"') || html.contains('action="/f/')) {
            await c.evaluateJavascript(source: '''
              var form = document.querySelector('form#dl') ||
                         document.querySelector('form[action*="/f/"]');
              if (form) form.submit();
            ''');
          }
        },
        onReceivedError: (c, req, err) {
          widget.onError(Exception('WebView error: ${err.description}'));
        },
      ),
    );
  }
}
