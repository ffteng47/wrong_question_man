// lib/utils/draft_helper.dart
//
// 草稿任务表：记录"已上传但尚未提取成功"的图片
// 服务端重启后，客户端可凭 image_id 直接重试 /extract，无需重新上传
//
// 与 DbHelper 共用同一个 wrong_answer.db（由 DbHelper 管理 version 2 升级）
//
import 'package:sqflite/sqflite.dart';
import 'db_helper.dart';

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

  DraftHelper._();
  static DraftHelper get instance => _instance ??= DraftHelper._();

  // 复用 DbHelper 的数据库连接（避免版本竞争）
  Future<Database> get _db async => DbHelper.instance.db;

  // ── 写入草稿 ──────────────────────────────────────────────────────────────
  Future<void> upsert(DraftTask task) async {
    final d = await _db;
    await d.insert('draft_tasks', task.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ── 更新状态 ──────────────────────────────────────────────────────────────
  Future<void> updateStatus(
    String id,
    DraftStatus status, {
    String? errorMsg,
  }) async {
    final d = await _db;
    await d.update(
      'draft_tasks',
      {'status': status.index, 'error_msg': errorMsg},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ── 查询所有待处理草稿（uploadOk + extractFailed）────────────────────────
  Future<List<DraftTask>> pendingTasks() async {
    final d = await _db;
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
    final d = await _db;
    await d.delete('draft_tasks', where: 'id = ?', whereArgs: [id]);
  }

  // ── 待处理数量（首页角标用）──────────────────────────────────────────────
  Future<int> pendingCount() async {
    final d = await _db;
    final result = await d.rawQuery(
      'SELECT COUNT(*) FROM draft_tasks WHERE status = ? OR status = ?',
      [DraftStatus.uploadOk.index, DraftStatus.extractFailed.index],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }
}
