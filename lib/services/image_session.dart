import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'cf_session.dart';
import 'domain_resolver.dart';

/// Reads poster and snapshot bytes from the image host.
///
/// Why this needs its own WebView at all:
///
///  * A plain HTTP request to `i.animepahe.*` is answered 403. It sits behind
///    its own Cloudflare protection, and neither a Referer nor the main site's
///    clearance cookie is accepted.
///  * Reading it from inside the main site's page fails with
///    "TypeError: Load failed" — the image host is a different origin serving
///    no CORS headers, and the same-origin policy is a browser rule that no
///    amount of cookie juggling gets around.
///
/// So the bytes are read from a page *on the image host itself*, where they
/// are same-origin and the policy does not apply.
///
/// An earlier attempt at this ran the second WebView alongside the main
/// Cloudflare challenge and starved it, leaving the app stuck on a loading
/// screen. This one is only started once the main session is already cleared,
/// so the two never compete.
class ImageSession {
  static final ImageSession _i = ImageSession._();
  ImageSession._();
  factory ImageSession() => _i;

  InAppWebViewController? _controller;
  final _ready = Completer<void>();

  bool get isReady => _controller != null && _ready.isCompleted;

  /// The image host for the currently live domain. The API hands out asset
  /// URLs on whatever host it was written against, so this is derived from the
  /// resolved site domain rather than trusted from the payload.
  static String get origin {
    final tld = DomainResolver.host.split('.').last;
    return 'https://i.animepahe.$tld';
  }

  void _attach(InAppWebViewController c) => _controller = c;

  /// Marked ready only once a page on the image host has actually loaded.
  ///
  /// Signalling readiness when the controller was created was too early: the
  /// WebView is still on about:blank at that point, so a fetch issued from it
  /// is cross-origin and fails with "TypeError: Load failed". That race cost
  /// the first poster on screen every launch.
  void _markLoaded() {
    if (!_ready.isCompleted) _ready.complete();
  }

  /// Waits for the host page to be up. Posters requested during startup would
  /// otherwise fail before it had a chance to load.
  Future<void> _waitReady() =>
      _ready.future.timeout(const Duration(seconds: 20), onTimeout: () {});

  Future<Uint8List> fetchBytes(String url) async {
    await _waitReady();
    final c = _controller;
    if (c == null) throw StateError('image session is not ready');

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
      throw Exception('image failed: ${result!.error}');
    }
    final b64 = result?.value;
    if (b64 is! String || b64.isEmpty) throw Exception('empty image $url');
    return base64Decode(b64);
  }
}

/// Parks a WebView on the image host so [ImageSession] can read from it.
///
/// Mount once, below the app's own UI. It must not be given a zero or
/// one-pixel size: the platform throttles work for a view it considers
/// invisible, which is the same trap that stopped the main Cloudflare check
/// from ever completing.
class ImageSessionHost extends StatefulWidget {
  const ImageSessionHost({super.key});

  @override
  State<ImageSessionHost> createState() => _ImageSessionHostState();
}

class _ImageSessionHostState extends State<ImageSessionHost> {
  final _key = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: InAppWebView(
        key: _key,
        initialUrlRequest: URLRequest(
          url: WebUri('${ImageSession.origin}/favicon.ico'),
          headers: {'Referer': DomainResolver.referer},
        ),
        initialUserScripts: kShadeUserScripts,
        initialSettings: InAppWebViewSettings(
          userAgent: CfSession.webViewUserAgent,
          applicationNameForUserAgent: 'Version/17.4 Safari/605.1.15',
          javaScriptEnabled: true,
          domStorageEnabled: true,
          databaseEnabled: true,
          thirdPartyCookiesEnabled: true,
          clearCache: false,
          incognito: false,
          transparentBackground: true,
        ),
        onWebViewCreated: ImageSession()._attach,
        onLoadStop: (c, url) {
          debugPrint('IMGHOST: loaded $url');
          ImageSession()._markLoaded();
        },
        onReceivedError: (c, req, err) =>
            debugPrint('IMGHOST: error ${req.url} -> ${err.description}'),
      ),
    );
  }
}
