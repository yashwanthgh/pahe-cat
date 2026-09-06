/// One playable/downloadable option for an episode.
///
/// animepahe's play page exposes two different links per option, and they are
/// not interchangeable:
///
///  * [kwikUrl] — a `kwik.cx/e/<hash>` embed. This is a player page serving
///    HLS through hls.js, so the `<video>` element's source is a `blob:` URL.
///    There is no file to hand to a downloader; it can only be played.
///  * [downloadUrl] — a `pahe.win/<id>` link from the download menu, which
///    redirects to a kwik download page that yields a real MP4. This is the
///    only route that produces a file, and the only place the size is listed.
class StreamSource {
  final String quality; // 360p, 720p, 1080p
  final String kwikUrl; // kwik.cx/e/<hash> — streaming only
  final String downloadUrl; // pahe.win/<id> — downloading only
  final String audio; // jpn (sub) / eng (dub)
  final String fileSize;
  final String fansub;

  const StreamSource({
    required this.quality,
    required this.kwikUrl,
    required this.audio,
    required this.fileSize,
    this.downloadUrl = '',
    this.fansub = '',
  });

  StreamSource copyWith({
    String? quality,
    String? kwikUrl,
    String? downloadUrl,
    String? audio,
    String? fileSize,
    String? fansub,
  }) =>
      StreamSource(
        quality: quality ?? this.quality,
        kwikUrl: kwikUrl ?? this.kwikUrl,
        downloadUrl: downloadUrl ?? this.downloadUrl,
        audio: audio ?? this.audio,
        fileSize: fileSize ?? this.fileSize,
        fansub: fansub ?? this.fansub,
      );

  bool get isDub =>
      audio.toLowerCase().contains('eng') ||
      audio.toLowerCase().contains('dub');
  String get audioLabel => isDub ? 'DUB' : 'SUB';

  bool get canStream => kwikUrl.isNotEmpty;
  bool get canDownload => downloadUrl.isNotEmpty;

  String get label =>
      '$quality · $audioLabel${fileSize.isNotEmpty ? " · $fileSize" : ""}';
}
