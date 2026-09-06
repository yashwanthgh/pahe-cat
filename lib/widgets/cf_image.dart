import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/image_session.dart';
import '../theme.dart';

/// Loads an animepahe poster or snapshot.
///
/// Goes through [ImageSession], which reads the bytes from a page on the image
/// host itself. Neither of the simpler routes works: a direct request is
/// answered 403 by that host's own Cloudflare, and reading it from the main
/// site's page is refused by the same-origin policy.
///
/// Requests are capped so a screen full of posters cannot queue dozens of
/// simultaneous evaluations against the single shared WebView.
class CfImageProvider extends ImageProvider<CfImageProvider> {
  final String url;

  const CfImageProvider(this.url);

  static final _gate = _Gate(3);

  @override
  Future<CfImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<CfImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
      CfImageProvider key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode),
      scale: 1.0,
      debugLabel: key.url,
    );
  }

  Future<ui.Codec> _load(
      CfImageProvider key, ImageDecoderCallback decode) async {
    await _gate.acquire();
    try {
      final bytes = await ImageSession().fetchBytes(key.url);
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      // Awaited so the gate is not released until decoding finishes.
      return await decode(buffer);
    } catch (e) {
      // Surfaced explicitly: Image's errorBuilder swallows this, which made
      // the poster failures impossible to diagnose from logs.
      debugPrint('CfImage failed for ${key.url}: $e');
      rethrow;
    } finally {
      _gate.release();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is CfImageProvider && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => 'CfImageProvider("$url")';
}

/// Drop-in replacement for the network image widget, with the placeholder and
/// error states the poster grid expects.
class CfImage extends StatelessWidget {
  final String url;
  final BoxFit fit;
  final double? width;
  final double? height;

  const CfImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return _placeholder(icon: Icons.image_not_supported_rounded);

    return Image(
      image: CfImageProvider(url),
      fit: fit,
      width: width,
      height: height,
      gaplessPlayback: true,
      frameBuilder: (ctx, child, frame, wasSync) {
        if (wasSync || frame != null) return child;
        return _placeholder();
      },
      errorBuilder: (ctx, err, stack) =>
          _placeholder(icon: Icons.broken_image_rounded),
    );
  }

  Widget _placeholder({IconData? icon}) => Container(
        width: width,
        height: height,
        color: PaheColors.cardHover,
        child: icon == null
            ? null
            : Center(
                child: Icon(icon, color: PaheColors.textMuted, size: 20),
              ),
      );
}

/// Limits how many image reads run against the shared WebView at once.
class _Gate {
  final int max;
  int _active = 0;
  final _queue = <Completer<void>>[];

  _Gate(this.max);

  Future<void> acquire() {
    if (_active < max) {
      _active++;
      return Future.value();
    }
    final c = Completer<void>();
    _queue.add(c);
    return c.future;
  }

  void release() {
    if (_queue.isNotEmpty) {
      _queue.removeAt(0).complete();
    } else {
      _active--;
    }
  }
}
