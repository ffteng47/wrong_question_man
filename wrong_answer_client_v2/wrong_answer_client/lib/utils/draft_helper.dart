// lib/utils/draft_helper.dart
//
// 草稿任务表：记录"已上传但尚未提取成功"的图片
// 服务端重启后，客户端可凭 image_id 直接重试 /extract，无需重新上传
//
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

// 草稿状态
enum DraftStatus {
  uploadPending,   // 上传中（异常退出时可能残留）
  uploadOk,        // 上传成功，等待 extract
  extractFailed,   // extract 失败（网络/模型错误）
}

class DraftTask {
  final String id;           // 本地唯一 ID（UUID）
  final String imageId;      // 服务端返回的 image_id
  final String localPath;    // 手机本地图片路径（用于预览缩略图）
  final String imageSource;  // camera | scanner
  final int widthPx;
  final int heightPx;
  final DraftStatus status;
  final String? errorMsg;
  final String createdAt;

  DraftTask({
    required this.id,
    required this.imageId,
    required this.localPath,
    required this.imageSource,
    required this.widthPx,
    required this.heightPx,
    required this.status,
    this.errorMsg,
    required this.createdAt,
  });

  factory DraftTask.fromMap(Map<String, dynamic> m) => DraftTask(
    id: m['id'] as String,
    imageId: m['image_id'] as String,
    localPath: m['local_path'] as String,
    imageSource: m['image_source'] as String,
    widthPx: m['width_px'] as int,
    heightPx: m['height_px'] as int,
    status: DraftStatus.values[m['status'] as int],
    errorMsg: m['error_msg'] as String?,
    createdAt: m['created_at'] as String,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'image_id': imageId,
    'local_path': localPath,
    'image_source': imageSource,
    'width_px': widthPx,
    'height_px': heightPx,
    'status': status.index,
    'error_msg': errorMsg,
    'created_at': createdAt,
  };
}

class DraftHelper {
  static DraftHelper? _instance;
  static Database? _db;

  DraftHelper._();
  static DraftHelper get instance => _instance ??= DraftHelper._();

  Future<Database> get db async => _db ??= await _initDb();

  Future<Database> _initDb() async {
    final dbPath = join(await getDatabasesPath(), 'wrong_answer.db');
    // 与 DbHelper 共用同一个数据库文件，version 升级到 2
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
        id           TEXT PRIMARY KEY,
        subject      TEXT NOT NULL DEFAULT '',
        grade        TEXT NOT NULL DEFAULT '',
        type         TEXT NOT NULL DEFAULT '',
        difficulty   INTEGER NOT NULL DEFAULT 3,
        review_status TEXT NOT NULL DEFAULT 'pending',
        created_at   TEXT NOT NULL,
        updated_at   TEXT NOT NULL,
        tags_json    TEXT NOT NULL DEFAULT '[]',
        data_json    TEXT NOT NULL
      )
    ''');
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
    await db.execute('CREATE INDEX IF NOT EXISTS idx_draft_status ON draft_tasks(status)');
  }

  // ── 写入草稿 ──────────────────────────────────────────────────────────────
  Future<void> upsert(DraftTask task) async {
    final d = await db;
    await d.insert('draft_tasks', task.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ── 更新状态 ──────────────────────────────────────────────────────────────
  Future<void> updateStatus(
    String id,
    DraftStatus status, {
    String? errorMsg,
  }) async {
    final d = await db;
    await d.update(
      'draft_tasks',
      {'status': status.index, 'error_msg': errorMsg},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ── 查询所有待处理草稿（uploadOk + extractFailed）────────────────────────
  Future<List<DraftTask>> pendingTasks() async {
    final d = await db;
    final rows = await d.query(
      'draft_tasks',
      where: 'status = ? OR status = ?',
      whereArgs: [
        DraftStatus.uploadOk.index,
        DraftStatus.extractFailed.index,
      ],
      orderBy: 'created_at DESC',
    );
    return rows.map(DraftTask.fromMap).toList();
  }

  // ── 删除草稿（extract 成功后调用）────────────────────────────────────────
  Future<void> delete(String id) async {
    final d = await db;
    await d.delete('draft_tasks', where: 'id = ?', whereArgs: [id]);
  }

  // ── 待处理数量（首页角标用）──────────────────────────────────────────────
  Future<int> pendingCount() async {
    final d = await db;
    final result = await d.rawQuery(
      'SELECT COUNT(*) FROM draft_tasks WHERE status = ? OR status = ?',
      [DraftStatus.uploadOk.index, DraftStatus.extractFailed.index],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }
}
