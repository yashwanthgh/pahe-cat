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

  /// Where to start, as a 0-1 fraction. Recording a position is only half of
  /// resuming — without seeking to it the player always began at zero.
  final double startAt;

  const WebPlayerScreen({
    super.key,
    required this.kwikUrl,
    required this.title,
    this.subtitle = '',
    this.onProgress,
    this.startAt = 0,
  });

  @override
  State<WebPlayerScreen> createState() => _WebPlayerScreenState();
}

/// Finds the video element wherever kwik put it.
///
/// A plain `document.querySelector('video')` is not enough: the player may sit
/// inside a nested frame, in which case the top document has no video at all
/// and the position silently never records — which looks exactly like an
/// episode nobody watched, so resume never fires. Same-origin frames are
/// searched too; a cross-origin one throws on access and is skipped.
const String _videoFinder = r'''
  function pcFindVideo() {
    var v = document.querySelector('video');
    if (v) return v;
    for (var i = 0; i < window.frames.length; i++) {
      try {
        var d = window.frames[i].document;
        var f = d && d.querySelector('video');
        if (f) return f;
      } catch (e) { /* cross-origin frame */ }
    }
    return null;
  }
''';

class _WebPlayerScreenState extends State<WebPlayerScreen> {
  InAppWebViewController? _c;
  Timer? _poll;
  Timer? _seekTimer;
  bool _loading = true;
  bool _sought = false;
  double _fraction = 0;
  String _lastDiag = '';

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
    _seekTimer?.cancel();
    if (_fraction > _openedMarker) widget.onProgress?.call(_fraction);
    super.dispose();
  }

  /// Seeks to the saved position once the video knows how long it is.
  ///
  /// The duration is not available at load: hls.js has to fetch the playlist
  /// first, so a seek attempted immediately is silently discarded. This keeps
  /// trying briefly and gives up rather than fighting a video that never
  /// reports a duration.
  void _seekToStart() {
    if (widget.startAt <= 0.01 || _sought) return;
    var attempts = 0;
    _seekTimer?.cancel();
    _seekTimer = Timer.periodic(const Duration(milliseconds: 500), (t) async {
      final c = _c;
      if (!mounted || _sought || c == null || ++attempts > 40) {
        t.cancel();
        return;
      }
      try {
        final r = await c.evaluateJavascript(source: '''
          (function () {
            $_videoFinder
            var v = pcFindVideo();
            if (!v || !v.duration || !isFinite(v.duration)) return '0';
            v.currentTime = ${widget.startAt} * v.duration;
            return '1';
          })()
        ''');
        if (r?.toString().trim() == '1') {
          _sought = true;
          _fraction = widget.startAt;
          t.cancel();
        }
      } catch (_) {
        // Retried on the next tick.
      }
    });
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
        final r = await c.evaluateJavascript(source: '''
          (function () {
            $_videoFinder
            var v = pcFindVideo();
            if (!v) return 'novideo:frames=' + window.frames.length;
            if (!v.duration || !isFinite(v.duration)) return 'noduration';
            return (v.currentTime / v.duration).toFixed(4);
          })()
        ''');
        final raw = r?.toString().trim() ?? '';
        // Reported because a player that hands back no position is
        // indistinguishable from an episode nobody watched, and that
        // difference is exactly what decides whether resume works.
        if (raw.startsWith('novideo') || raw == 'noduration') {
          if (_lastDiag != raw) {
            _lastDiag = raw;
            debugPrint('PLAYER: no position available ($raw)');
          }
          return;
        }
        final f = double.tryParse(raw);
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
                        _seekToStart();
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
