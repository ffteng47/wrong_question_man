// lib/services/sync_service.dart
// 将本地错题同步到 semecTeaching 云端

import 'dart:io';
import '../api/semec_teaching_api.dart';
import '../models/wrong_answer_record.dart';
import '../utils/db_helper.dart';

/// 同步结果
class SyncResult {
  final bool success;
  final bool studentSaved;
  final bool teacherSaved;
  final int? incorrectId;
  final String? studentIncorrectId;
  final String? teacherIncorrectId;
  final String? error;
  final bool uploadedImages;

  SyncResult({
    required this.success,
    this.studentSaved = false,
    this.teacherSaved = false,
    this.incorrectId,
    this.studentIncorrectId,
    this.teacherIncorrectId,
    this.error,
    this.uploadedImages = false,
  });
}

class SyncService {
  static SyncService? _instance;
  final SemecTeachingApi _api = SemecTeachingApi.instance;

  SyncService._();
  static SyncService get instance => _instance ??= SyncService._();

  /// 检查是否已登录 semecTeaching
  bool get isLoggedIn => _api.isLoggedIn;

  /// 获取当前登录用户
  SemecUser? get currentUser => _api.currentUser;

  /// 将单条本地记录同步到 semecTeaching
  ///
  /// 流程：
  /// 1. 检查登录状态
  /// 2. 上传相关图片（如果有）
  /// 3. 转换数据格式并保存
  Future<SyncResult> syncRecord(WrongAnswerRecord record) async {
    // 1. 检查登录
    if (!isLoggedIn) {
      return SyncResult(
        success: false,
        error: '未登录 semecTeaching，请先登录',
      );
    }

    final user = currentUser!;

    // 2. 上传图片（如果有 assets）
    List<String>? imageUrls;
    bool uploadedAny = false;

    if (record.assets.isNotEmpty) {
      imageUrls = [];
      for (final asset in record.assets) {
        final file = File(asset.srcPath);
        if (await file.exists()) {
          final uploadResult = await _api.uploadImage(file);
          if (uploadResult.success && uploadResult.url != null) {
            imageUrls.add(uploadResult.url!);
            uploadedAny = true;
          }
          // 单张图片失败不影响整体，记录即可
        }
      }
      if (imageUrls.isEmpty) imageUrls = null;
    }

    // 3. 保存错题
    final saveResult = await _api.saveIncorrectQuestion(
      userId: user.id,
      subject: record.subject,
      problem: record.problem,
      grade: record.grade,
      knowledgePoints:
          record.knowledgePoints.isNotEmpty ? record.knowledgePoints : null,
      answer: record.answer.isNotEmpty ? record.answer : null,
      solution: record.solution.isNotEmpty ? record.solution : null,
      studentAnswer: record.errorAnalysis.studentAnswer.isNotEmpty
          ? record.errorAnalysis.studentAnswer
          : null,
      errorCategory: record.errorAnalysis.errorCategory != '未知'
          ? record.errorAnalysis.errorCategory
          : null,
      errorDesc: record.errorAnalysis.errorDesc.isNotEmpty
          ? record.errorAnalysis.errorDesc
          : null,
      images: imageUrls,
      difficulty: record.difficulty,
      realScore: record.realScore,
    );

    if (saveResult.success) {
      return SyncResult(
        success: true,
        studentSaved: true,
        teacherSaved: true,
        incorrectId: saveResult.incorrectId,
        uploadedImages: uploadedAny,
      );
    } else {
      return SyncResult(
        success: false,
        error: saveResult.error ?? '同步失败',
        uploadedImages: uploadedAny,
      );
    }
  }

  /// 批量同步（用于后续扩展）
  Future<List<SyncResult>> syncBatch(List<WrongAnswerRecord> records) async {
    final results = <SyncResult>[];
    for (final record in records) {
      results.add(await syncRecord(record));
    }
    return results;
  }

  /// 教师分配错题给学生
  ///
  /// 流程：
  /// 1. 检查登录状态
  /// 2. 上传相关图片（如果有）
  /// 3. 调用 semecTeaching API，user_id = 目标学生ID（教师代保存）
  Future<SyncResult> assignToStudent({
    required WrongAnswerRecord record,
    required int targetUserId,
    required bool keepLocal,
  }) async {
    // 1. 检查登录
    if (!isLoggedIn) {
      return SyncResult(
        success: false,
        error: '未登录 semecTeaching，请先登录',
      );
    }

    // 2. 上传图片（如果有 assets）
    List<String>? imageUrls;
    bool uploadedAny = false;

    if (record.assets.isNotEmpty) {
      imageUrls = [];
      for (final asset in record.assets) {
        final file = File(asset.srcPath);
        if (await file.exists()) {
          final uploadResult = await _api.uploadImage(file);
          if (uploadResult.success && uploadResult.url != null) {
            imageUrls.add(uploadResult.url!);
            uploadedAny = true;
          }
        }
      }
      if (imageUrls.isEmpty) imageUrls = null;
    }

    // 3. 保存到学生库（主流程）
    final studentResult = await _api.saveIncorrectQuestion(
      userId: targetUserId,
      subject: record.subject,
      problem: record.problem,
      grade: record.grade,
      knowledgePoints:
          record.knowledgePoints.isNotEmpty ? record.knowledgePoints : null,
      answer: record.answer.isNotEmpty ? record.answer : null,
      solution: record.solution.isNotEmpty ? record.solution : null,
      studentAnswer: record.errorAnalysis.studentAnswer.isNotEmpty
          ? record.errorAnalysis.studentAnswer
          : null,
      errorCategory: record.errorAnalysis.errorCategory != '未知'
          ? record.errorAnalysis.errorCategory
          : null,
      errorDesc: record.errorAnalysis.errorDesc.isNotEmpty
          ? record.errorAnalysis.errorDesc
          : null,
      images: imageUrls,
      difficulty: record.difficulty,
      realScore: record.realScore,
    );

    // 4. 如保留到教师错题本，非阻塞保存到教师自己的云端
    bool teacherSaved = false;
    String? teacherError;
    int? teacherIncorrectId;

    if (keepLocal && studentResult.success) {
      try {
        final teacherUser = _api.currentUser!;
        final tResult = await _api.saveIncorrectQuestion(
          userId: teacherUser.id,
          subject: record.subject,
          problem: record.problem,
          grade: record.grade,
          knowledgePoints: record.knowledgePoints.isNotEmpty
              ? record.knowledgePoints : null,
          answer: record.answer.isNotEmpty ? record.answer : null,
          solution: record.solution.isNotEmpty ? record.solution : null,
          studentAnswer: record.errorAnalysis.studentAnswer.isNotEmpty
              ? record.errorAnalysis.studentAnswer : null,
          errorCategory: record.errorAnalysis.errorCategory != '未知'
              ? record.errorAnalysis.errorCategory : null,
          errorDesc: record.errorAnalysis.errorDesc.isNotEmpty
              ? record.errorAnalysis.errorDesc : null,
          images: imageUrls,
          difficulty: record.difficulty,
          realScore: record.realScore,
        );
        teacherSaved = tResult.success;
        teacherIncorrectId = tResult.incorrectId;
        if (!tResult.success) teacherError = tResult.error;
      } catch (e) {
        teacherError = '教师错题库保存失败: $e';
      }
    }

    // 5. 本地 SQLite 更新
    if (keepLocal && studentResult.success) {
      record.assignedToStudentId = targetUserId.toString();
      record.assignStatus = 'assigned';
      await DbHelper.instance.upsert(record);
    }

    return SyncResult(
      success: studentResult.success,
      studentSaved: studentResult.success,
      teacherSaved: teacherSaved,
      incorrectId: studentResult.incorrectId,
      studentIncorrectId: studentResult.success
          ? studentResult.incorrectId?.toString() : null,
      teacherIncorrectId: teacherIncorrectId?.toString(),
      error: !studentResult.success
          ? studentResult.error ?? '分配失败'
          : teacherError,
      uploadedImages: uploadedAny,
    );
  }
}
