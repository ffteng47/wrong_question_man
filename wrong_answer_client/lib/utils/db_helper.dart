// lib/utils/db_helper.dart
import 'dart:convert';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../models/wrong_answer_record.dart';

class DbHelper {
  static DbHelper? _instance;
  static Database? _db;

  DbHelper._();
  static DbHelper get instance => _instance ??= DbHelper._();

  Future<Database> get db async => _db ??= await _initDb();

  Future<Database> _initDb() async {
    final dbPath = join(await getDatabasesPath(), 'wrong_answer.db');
    return openDatabase(
      dbPath,
      version: 2,
      onCreate: (db, version) async {
        await _createRecordsTable(db);
        await _createDraftTable(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _createDraftTable(db);
        }
      },
    );
  }

  Future<void> _createRecordsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS records (
        id          TEXT PRIMARY KEY,
        subject     TEXT NOT NULL DEFAULT '',
        grade       TEXT NOT NULL DEFAULT '',
        type        TEXT NOT NULL DEFAULT '',
        difficulty  INTEGER NOT NULL DEFAULT 3,
        review_status TEXT NOT NULL DEFAULT 'pending',
        created_at  TEXT NOT NULL,
        updated_at  TEXT NOT NULL,
        tags_json   TEXT NOT NULL DEFAULT '[]',
        data_json   TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_subject ON records(subject)');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_grade ON records(grade)');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_review ON records(review_status)');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_created ON records(created_at DESC)');
  }

  Future<void> _createDraftTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS draft_tasks (
        id           TEXT PRIMARY KEY,
        image_id     TEXT NOT NULL,
        local_path   TEXT NOT NULL,
        image_source TEXT NOT NULL DEFAULT 'camera',
        width_px     INTEGER NOT NULL DEFAULT 0,
        height_px    INTEGER NOT NULL DEFAULT 0,
        status       INTEGER NOT NULL DEFAULT 0,
        error_msg    TEXT,
        created_at   TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_draft_status ON draft_tasks(status)');
  }

  // ── 写入/更新 ─────────────────────────────────────────────────────────────
  Future<void> upsert(WrongAnswerRecord r) async {
    final d = await db;
    await d.insert(
      'records',
      {
        'id':            r.id,
        'subject':       r.subject,
        'grade':         r.grade,
        'type':          r.type,
        'difficulty':    r.difficulty,
        'review_status': r.reviewStatus,
        'created_at':    r.createdAt,
        'updated_at':    r.updatedAt,
        'tags_json':     jsonEncode(r.tags),
        'data_json':     r.toJsonString(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ── 查询列表 ──────────────────────────────────────────────────────────────
  Future<List<WrongAnswerRecord>> query({
    String? subject,
    String? grade,
    String? reviewStatus,
    int limit = 50,
    int offset = 0,
  }) async {
    final d = await db;
    final conditions = <String>[];
    final args = <Object>[];

    if (subject != null) { conditions.add('subject = ?'); args.add(subject); }
    if (grade != null)   { conditions.add('grade = ?');   args.add(grade); }
    if (reviewStatus != null) {
      conditions.add('review_status = ?');
      args.add(reviewStatus);
    }

    final where = conditions.isEmpty ? null : conditions.join(' AND ');
    final rows = await d.query(
      'records',
      where: where,
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'created_at DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map((r) =>
        WrongAnswerRecord.fromJson(
          jsonDecode(r['data_json'] as String) as Map<String, dynamic>))
        .toList();
  }

  // ── 单条读取 ──────────────────────────────────────────────────────────────
  Future<WrongAnswerRecord?> getById(String id) async {
    final d = await db;
    final rows = await d.query('records', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return WrongAnswerRecord.fromJson(
        jsonDecode(rows.first['data_json'] as String) as Map<String, dynamic>);
  }

  // ── 更新复习状态 ──────────────────────────────────────────────────────────
  Future<void> updateReviewStatus(String id, String status) async {
    final r = await getById(id);
    if (r == null) return;
    r.reviewStatus = status;
    r.updatedAt = DateTime.now().toUtc().toIso8601String();
    await upsert(r);
  }

  // ── 删除 ──────────────────────────────────────────────────────────────────
  Future<void> delete(String id) async {
    final d = await db;
    await d.delete('records', where: 'id = ?', whereArgs: [id]);
  }

  // ── 统计 ──────────────────────────────────────────────────────────────────
  Future<Map<String, int>> stats() async {
    final d = await db;
    final total = Sqflite.firstIntValue(
        await d.rawQuery('SELECT COUNT(*) FROM records')) ?? 0;
    final mastered = Sqflite.firstIntValue(
        await d.rawQuery(
            "SELECT COUNT(*) FROM records WHERE review_status='mastered'")) ?? 0;
    final pending = Sqflite.firstIntValue(
        await d.rawQuery(
            "SELECT COUNT(*) FROM records WHERE review_status='pending'")) ?? 0;
    return {'total': total, 'mastered': mastered, 'pending': pending};
  }
}
