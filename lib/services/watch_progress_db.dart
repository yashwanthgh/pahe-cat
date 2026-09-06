import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/watch_progress.dart';
import 'preview_data.dart';

class WatchProgressDb {
  static Database? _db;

  /// Announces that stored progress changed.
  ///
  /// Screens cannot rely on the writer invalidating their caches. Progress is
  /// written from the player's own teardown, and from a route that has
  /// already been replaced by the player — its State is disposed by then, so
  /// any "if still mounted, invalidate" step is simply skipped, and the
  /// history list kept showing stale rows and a zeroed progress bar. Anything
  /// displaying progress listens here instead.
  static final _changes = StreamController<int>.broadcast();
  static Stream<int> get changes => _changes.stream;
  static int _revision = 0;

  static void _announce() {
    _revision++;
    if (!_changes.isClosed) _changes.add(_revision);
  }

  /// sqflite has no web implementation, so the design preview keeps progress
  /// in memory for the session instead of throwing on every screen.
  static final Map<String, WatchProgress> _memory = {};
  static final Map<String, EpisodeProgress> _epMemory = {};

  static Future<Database> get db async {
    _db ??= await _open();
    return _db!;
  }

  static const _createSeries = '''
    CREATE TABLE IF NOT EXISTS watch_progress (
      anime_session TEXT PRIMARY KEY,
      anime_title TEXT,
      anime_poster TEXT,
      last_episode INTEGER,
      total_episodes INTEGER,
      resume_episode INTEGER DEFAULT 0,
      resume_position REAL DEFAULT 0,
      updated_at INTEGER
    )
  ''';

  /// Per-episode rows, so an episode part-way through a long series is not
  /// lost when a later one is watched.
  static const _createEpisodes = '''
    CREATE TABLE IF NOT EXISTS episode_progress (
      anime_session TEXT NOT NULL,
      episode_number INTEGER NOT NULL,
      position REAL NOT NULL,
      updated_at INTEGER NOT NULL,
      PRIMARY KEY (anime_session, episode_number)
    )
  ''';

  static Future<Database> _open() async {
    final dir = await getDatabasesPath();
    final path = join(dir, 'pahe_cat.db');
    return openDatabase(
      path,
      version: 2,
      onCreate: (db, _) async {
        await db.execute(_createSeries);
        await db.execute(_createEpisodes);
      },
      // Existing installs keep their history: the new columns are added in
      // place rather than the table being recreated.
      onUpgrade: (db, from, to) async {
        if (from < 2) {
          await db.execute(_createEpisodes);
          for (final ddl in const [
            'ALTER TABLE watch_progress ADD COLUMN resume_episode INTEGER DEFAULT 0',
            'ALTER TABLE watch_progress ADD COLUMN resume_position REAL DEFAULT 0',
          ]) {
            try {
              await db.execute(ddl);
            } catch (_) {
              // Already present — an interrupted upgrade can leave one added.
            }
          }
        }
      },
    );
  }

  static Future<void> save(WatchProgress p) async {
    if (PreviewMode.enabled) {
      _memory[p.animeSession] = p;
      _announce();
      return;
    }
    final d = await db;
    await d.insert(
      'watch_progress',
      p.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _announce();
  }

  /// Records a position within one episode and rolls the series summary
  /// forward.
  ///
  /// [WatchProgress.lastEpisode] only ever increases. Writing the
  /// most-recently-opened episode instead meant rewatching an early episode
  /// threw away the viewer's place in the series.
  static Future<void> saveEpisode({
    required String animeSession,
    required String animeTitle,
    required String animePoster,
    required int episodeNumber,
    required int totalEpisodes,
    required double position,
  }) async {
    final now = DateTime.now();
    final ep = EpisodeProgress(
      animeSession: animeSession,
      episodeNumber: episodeNumber,
      position: position,
      updatedAt: now,
    );

    if (PreviewMode.enabled) {
      _epMemory['$animeSession/$episodeNumber'] = ep;
    } else {
      final d = await db;
      await d.insert('episode_progress', ep.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }

    final existing = await get(animeSession);
    // Only a finished episode advances the "furthest reached" count. Deriving
    // it from the episode merely opened claimed everything before it had been
    // watched, which is not something the app can know.
    final furthest = ep.isCompleted ? episodeNumber : (existing?.lastEpisode ?? 0);
    await save(WatchProgress(
      animeSession: animeSession,
      animeTitle: animeTitle.isEmpty ? (existing?.animeTitle ?? '') : animeTitle,
      animePoster:
          animePoster.isEmpty ? (existing?.animePoster ?? '') : animePoster,
      lastEpisode: furthest > (existing?.lastEpisode ?? 0)
          ? furthest
          : (existing?.lastEpisode ?? 0),
      totalEpisodes:
          totalEpisodes > 0 ? totalEpisodes : (existing?.totalEpisodes ?? 0),
      // The resume point is always the episode just watched, whether that is
      // ahead of or behind the furthest reached.
      resumeEpisode: episodeNumber,
      resumePosition: position,
      updatedAt: now,
    ));
  }

  static Future<EpisodeProgress?> getEpisode(
      String animeSession, int episodeNumber) async {
    if (PreviewMode.enabled) return _epMemory['$animeSession/$episodeNumber'];
    final d = await db;
    final rows = await d.query(
      'episode_progress',
      where: 'anime_session = ? AND episode_number = ?',
      whereArgs: [animeSession, episodeNumber],
    );
    return rows.isEmpty ? null : EpisodeProgress.fromMap(rows.first);
  }

  /// Every episode of one series that has been started, keyed by number, so
  /// the episode list can mark them in one query rather than one per row.
  static Future<Map<int, EpisodeProgress>> getEpisodes(
      String animeSession) async {
    if (PreviewMode.enabled) {
      return {
        for (final e in _epMemory.values)
          if (e.animeSession == animeSession) e.episodeNumber: e,
      };
    }
    final d = await db;
    final rows = await d.query(
      'episode_progress',
      where: 'anime_session = ?',
      whereArgs: [animeSession],
    );
    final out = <int, EpisodeProgress>{};
    for (final r in rows) {
      final e = EpisodeProgress.fromMap(r);
      out[e.episodeNumber] = e;
    }
    return out;
  }

  static Future<WatchProgress?> get(String animeSession) async {
    if (PreviewMode.enabled) return _memory[animeSession];
    final d = await db;
    final rows = await d.query(
      'watch_progress',
      where: 'anime_session = ?',
      whereArgs: [animeSession],
    );
    if (rows.isEmpty) return null;
    return WatchProgress.fromMap(rows.first);
  }

  static Future<List<WatchProgress>> getAll() async {
    if (PreviewMode.enabled) {
      return _memory.values.toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    }
    final d = await db;
    final rows = await d.query('watch_progress', orderBy: 'updated_at DESC');
    return rows.map(WatchProgress.fromMap).toList();
  }

  static Future<void> delete(String animeSession) async {
    if (PreviewMode.enabled) {
      _memory.remove(animeSession);
      _epMemory.removeWhere((k, _) => k.startsWith('$animeSession/'));
      _announce();
      return;
    }
    final d = await db;
    await d.delete('watch_progress',
        where: 'anime_session = ?', whereArgs: [animeSession]);
    await d.delete('episode_progress',
        where: 'anime_session = ?', whereArgs: [animeSession]);
    _announce();
  }
}
