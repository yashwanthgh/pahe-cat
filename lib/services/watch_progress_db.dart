import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/watch_progress.dart';

class WatchProgressDb {
  static Database? _db;

  static Future<Database> get db async {
    _db ??= await _open();
    return _db!;
  }

  static Future<Database> _open() async {
    final dir = await getDatabasesPath();
    final path = join(dir, 'pahe_boy.db');
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, _) => db.execute('''
        CREATE TABLE watch_progress (
          anime_session TEXT PRIMARY KEY,
          anime_title TEXT,
          anime_poster TEXT,
          last_episode INTEGER,
          total_episodes INTEGER,
          updated_at INTEGER
        )
      '''),
    );
  }

  static Future<void> save(WatchProgress p) async {
    final d = await db;
    await d.insert(
      'watch_progress',
      p.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<WatchProgress?> get(String animeSession) async {
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
    final d = await db;
    final rows = await d.query(
      'watch_progress',
      orderBy: 'updated_at DESC',
    );
    return rows.map(WatchProgress.fromMap).toList();
  }

  static Future<void> delete(String animeSession) async {
    final d = await db;
    await d.delete(
      'watch_progress',
      where: 'anime_session = ?',
      whereArgs: [animeSession],
    );
  }
}
