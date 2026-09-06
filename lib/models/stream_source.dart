class StreamSource {
  final String quality; // 360p, 720p, 1080p
  final String kwikUrl; // kwik.si/e/<hash>
  final String audio; // sub / eng (dub)
  final String fileSize;

  const StreamSource({
    required this.quality,
    required this.kwikUrl,
    required this.audio,
    required this.fileSize,
  });

  bool get isDub =>
      audio.toLowerCase().contains('eng') ||
      audio.toLowerCase().contains('dub');
  String get audioLabel => isDub ? 'DUB' : 'SUB';
  String get label => '$quality · $audioLabel${fileSize.isNotEmpty ? " · $fileSize" : ""}';
}
