import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../services/cf_session.dart';
import '../services/domain_resolver.dart';
import '../theme.dart';

/// Plays an episode by running kwik's own embed page.
///
/// There is deliberately no URL extraction here. kwik serves HLS through
/// hls.js, which feeds the `<video>` element from a MediaSource — so its
/// `src` is a `blob:` URL that means nothing outside that page, and no MP4
/// exists to hand to an external player. Earlier attempts to pull a direct
/// link out of this page could not have worked for that reason.
///
/// Running the embed also gets HLS playback, quality switching and subtitle
/// rendering for free on every platform, which a Dart-side player would each
/// have to reimplement.
class WebPlayerScreen extends StatefulWidget {
  final String kwikUrl;
  final String title;
  final String subtitle;

  /// Reports how far through the episode the viewer is, as a 0-1 fraction.
  ///
  /// Called as soon as the player opens, again while it plays, and once more
  /// on the way out. Reporting only on the way out meant a short visit
  /// recorded nothing at all, so the app still pointed at whichever episode
  /// had been watched before this one.
  final void Function(double fraction)? onProgress;

  const WebPlayerScreen({
    super.key,
    required this.kwikUrl,
    required this.title,
    this.subtitle = '',
    this.onProgress,
  });

  @override
  State<WebPlayerScreen> createState() => _WebPlayerScreenState();
}

class _WebPlayerScreenState extends State<WebPlayerScreen> {
  InAppWebViewController? _c;
  Timer? _poll;
  bool _loading = true;
  double _fraction = 0;

  @override
  void initState() {
    super.initState();
    // Recorded straight away so opening an episode moves the resume pointer
    // even if it is closed again before playback gets going.
    widget.onProgress?.call(_openedMarker);
  }

  /// Small enough not to be mistaken for real viewing, large enough to mark
  /// this as the episode in progress.
  static const _openedMarker = 0.01;

  @override
  void dispose() {
    _poll?.cancel();
    if (_fraction > _openedMarker) widget.onProgress?.call(_fraction);
    super.dispose();
  }

  /// Reads playback position straight off the video element.
  ///
  /// This is the whole point of the app — animepahe has no accounts, so
  /// progress has to be observed locally — and the embed exposes it plainly.
  void _startTracking() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) async {
      final c = _c;
      if (c == null || !mounted) return;
      try {
        final r = await c.evaluateJavascript(source: r'''
          (function () {
            var v = document.querySelector('video');
            if (!v || !v.duration || !isFinite(v.duration)) return '';
            return (v.currentTime / v.duration).toFixed(4);
          })()
        ''');
        final f = double.tryParse(r?.toString().trim() ?? '');
        // Monotonic: the furthest point reached is what gets remembered.
        if (f != null && f > _fraction) {
          _fraction = f;
          // Written as it goes, so progress survives the app being killed
          // rather than only a clean exit through the back button.
          widget.onProgress?.call(_fraction);
        }
      } catch (_) {
        // A transient evaluation failure is not worth surfacing.
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _PlayerBar(title: widget.title, subtitle: widget.subtitle),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: InAppWebView(
                      initialUrlRequest: URLRequest(
                        url: WebUri(widget.kwikUrl),
                        // kwik refuses to serve the player to a request that
                        // did not come from animepahe.
                        headers: {'Referer': DomainResolver.referer},
                      ),
                      initialSettings: InAppWebViewSettings(
                        userAgent: CfSession.webViewUserAgent,
                        applicationNameForUserAgent:
                            'Version/17.4 Safari/605.1.15',
                        javaScriptEnabled: true,
                        domStorageEnabled: true,
                        thirdPartyCookiesEnabled: true,
                        transparentBackground: true,
                        // Playback has to be able to start without the viewer
                        // hunting for a play button inside the embed.
                        mediaPlaybackRequiresUserGesture: false,
                        allowsInlineMediaPlayback: true,
                        iframeAllowFullscreen: true,
                      ),
                      onWebViewCreated: (c) => _c = c,
                      onLoadStop: (c, url) {
                        if (mounted) setState(() => _loading = false);
                        _startTracking();
                      },
                      // The embed pops adverts on click. Anything that is not
                      // the player itself is refused rather than followed.
                      onCreateWindow: (c, req) async => false,
                      shouldOverrideUrlLoading: (c, action) async {
                        final url = action.request.url?.toString() ?? '';
                        if (action.isForMainFrame &&
                            !url.contains('kwik.') &&
                            !url.startsWith('about:')) {
                          return NavigationActionPolicy.CANCEL;
                        }
                        return NavigationActionPolicy.ALLOW;
                      },
                    ),
                  ),
                  if (_loading)
                    const Positioned.fill(
                      child: ColoredBox(
                        color: Colors.black,
                        child: Center(
                          child: CircularProgressIndicator(
                            color: PaheColors.accent,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlayerBar extends StatelessWidget {
  final String title;
  final String subtitle;
  const _PlayerBar({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(4, 6, 12, 6),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
            onPressed: () => Navigator.of(context).maybePop(),
            tooltip: 'Back',
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
