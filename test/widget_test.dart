import 'package:flutter_test/flutter_test.dart';
import 'package:pahe_boy/models/stream_source.dart';
import 'package:pahe_boy/models/watch_progress.dart';

void main() {
  test('StreamSource labels dub sources correctly', () {
    const dub = StreamSource(
      quality: '720p',
      kwikUrl: 'https://kwik.si/e/abc',
      audio: 'eng',
      fileSize: '250 MB',
    );
    const sub = StreamSource(
      quality: '1080p',
      kwikUrl: 'https://kwik.si/e/xyz',
      audio: 'jpn',
      fileSize: '',
    );

    expect(dub.isDub, isTrue);
    expect(dub.audioLabel, 'DUB');
    expect(sub.isDub, isFalse);
    expect(sub.audioLabel, 'SUB');
  });

  test('WatchProgress computes fraction and survives a round trip', () {
    final p = WatchProgress(
      animeSession: 's1',
      animeTitle: 'Test Anime',
      animePoster: 'https://example.com/p.jpg',
      lastEpisode: 6,
      totalEpisodes: 24,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );

    expect(p.progressFraction, closeTo(0.25, 0.0001));
    expect(p.progressLabel, '6 / 24 ep');

    final restored = WatchProgress.fromMap(p.toMap());
    expect(restored.animeSession, p.animeSession);
    expect(restored.lastEpisode, p.lastEpisode);
    expect(restored.updatedAt, p.updatedAt);
  });

  test('WatchProgress handles zero total episodes without dividing by zero', () {
    final p = WatchProgress(
      animeSession: 's2',
      animeTitle: 'Unknown',
      animePoster: '',
      lastEpisode: 0,
      totalEpisodes: 0,
      updatedAt: DateTime.now(),
    );
    expect(p.progressFraction, 0);
  });
}
