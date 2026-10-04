// lib/models/paper_models.dart
// 纸面作业判题链路（exam-server /api/answer/*）学生端模型
// 依据《纸面作业判题-详设文档 v1.0》§4.1 契约
import 'dart:ui' show Rect;

class PaperAssignment {
  final int assignId;
  final int? paperId;
  final String examTitle;
  final String? paperTitle;
  final String? subject;
  final String? gradeName;
  final String? teacherName;
  final String? endTime;
  final int uploadCount;

  PaperAssignment({
    required this.assignId,
    this.paperId,
    required this.examTitle,
    this.paperTitle,
    this.subject,
    this.gradeName,
    this.teacherName,
    this.endTime,
    this.uploadCount = 0,
  });

  factory PaperAssignment.fromJson(Map<String, dynamic> j) => PaperAssignment(
    assignId: (j['assign_id'] as num?)?.toInt() ?? 0,
    paperId: (j['paper_id'] as num?)?.toInt(),
    examTitle: j['exam_title'] ?? '',
    paperTitle: j['paper_title'],
    subject: j['subject'],
    gradeName: j['grade_name'],
    teacherName: j['teacher_name'],
    endTime: j['end_time']?.toString(),
    uploadCount: (j['upload_count'] as num?)?.toInt() ?? 0,
  );
}

class PaperUploadCreated {
  final int uploadId;
  final String uploadNo;
  final int totalPages;
  final String status;

  PaperUploadCreated({
    required this.uploadId,
    required this.uploadNo,
    required this.totalPages,
    required this.status,
  });

  factory PaperUploadCreated.fromJson(Map<String, dynamic> j) =>
      PaperUploadCreated(
        uploadId: (j['uploadId'] as num?)?.toInt() ?? 0,
        uploadNo: j['uploadNo'] ?? '',
        totalPages: (j['totalPages'] as num?)?.toInt() ?? 0,
        status: j['status'] ?? '已上传',
      );
}

class PaperUploadRow {
  final int id;
  final String uploadNo;
  final String? paperTitle;
  final int totalPages;
  final String status;
  final String createdAt;
  final String updatedAt;

  PaperUploadRow({
    required this.id,
    required this.uploadNo,
    this.paperTitle,
    required this.totalPages,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  factory PaperUploadRow.fromJson(Map<String, dynamic> j) => PaperUploadRow(
    id: (j['id'] as num?)?.toInt() ?? 0,
    uploadNo: j['upload_no'] ?? '',
    paperTitle: j['paper_title'],
    totalPages: (j['total_pages'] as num?)?.toInt() ?? 0,
    status: j['status'] ?? '',
    createdAt: j['created_at']?.toString() ?? '',
    updatedAt: j['updated_at']?.toString() ?? '',
  );

  /// 状态机终态（详设 §2.1）：不再需要轮询
  bool get isTerminal =>
      status == '完成' || status == '处理失败' ||
      status == '部分完成' || status == '等待人工确认';
}

class PaperPage {
  final int id;
  final int pageNo;
  final int? width;
  final int? height;

  PaperPage({required this.id, required this.pageNo, this.width, this.height});

  factory PaperPage.fromJson(Map<String, dynamic> j) => PaperPage(
    id: (j['id'] as num?)?.toInt() ?? 0,
    pageNo: (j['page_no'] as num?)?.toInt() ?? 0,
    width: (j['width'] as num?)?.toInt(),
    height: (j['height'] as num?)?.toInt(),
  );
}

/// 判题行学生安全视图（toStudentResult）
/// question_region 为 0~1000 归一化 [x1,y1,x2,y2]，唯一坐标来源
class PaperResult {
  final int resultId;
  final int pageId;
  final int? itemId;
  final String? matchStatus;
  final String? recognitionStatus;
  final String? questionText;
  final String? questionContent;
  final String? questionAnswer;
  final String? questionType;
  final String grade; // correct | wrong | partial | pending_teacher
  final double? score;
  final double? maxScore;
  final String? feedback;
  final String? reason;
  final String? recognizedText;
  final List<double>? questionRegion;

  PaperResult({
    required this.resultId,
    required this.pageId,
    this.itemId,
    this.matchStatus,
    this.recognitionStatus,
    this.questionText,
    this.questionContent,
    this.questionAnswer,
    this.questionType,
    required this.grade,
    this.score,
    this.maxScore,
    this.feedback,
    this.reason,
    this.recognizedText,
    this.questionRegion,
  });

  factory PaperResult.fromJson(Map<String, dynamic> j) {
    final region = (j['question_region'] as List?)
        ?.map((e) => (e as num).toDouble()).toList();
    return PaperResult(
      resultId: (j['result_id'] as num?)?.toInt() ?? 0,
      pageId: (j['page_id'] as num?)?.toInt() ?? 0,
      itemId: (j['item_id'] as num?)?.toInt(),
      matchStatus: j['match_status'],
      recognitionStatus: j['recognition_status'],
      questionText: j['question_text'],
      questionContent: j['question_content'],
      questionAnswer: j['question_answer'],
      questionType: j['question_type'],
      grade: j['grade'] ?? 'pending_teacher',
      score: (j['score'] as num?)?.toDouble(),
      maxScore: (j['max_score'] as num?)?.toDouble(),
      feedback: j['feedback'],
      reason: j['reason'],
      recognizedText: j['recognized_text'],
      questionRegion: (region != null && region.length == 4) ? region : null,
    );
  }

  String get gradeLabel => switch (grade) {
    'correct' => '正确',
    'wrong' => '错误',
    'partial' => '部分正确',
    _ => '需老师确认',
  };

  /// 0~1000 → 百分比定位（left/top/width/height，0~1）
  Rect? get regionFraction {
    final r = questionRegion;
    if (r == null) return null;
    return Rect.fromLTRB(r[0] / 1000, r[1] / 1000, r[2] / 1000, r[3] / 1000);
  }
}

class PaperUploadDetail {
  final int id;
  final String uploadNo;
  final String status;
  final int totalPages;
  final List<PaperPage> pages;
  final List<PaperResult> results;

  PaperUploadDetail({
    required this.id,
    required this.uploadNo,
    required this.status,
    required this.totalPages,
    required this.pages,
    required this.results,
  });

  factory PaperUploadDetail.fromJson(Map<String, dynamic> j) =>
      PaperUploadDetail(
        id: (j['id'] as num?)?.toInt() ?? 0,
        uploadNo: j['upload_no'] ?? '',
        status: j['status'] ?? '',
        totalPages: (j['total_pages'] as num?)?.toInt() ?? 0,
        pages: (j['pages'] as List? ?? [])
            .map((e) => PaperPage.fromJson(e)).toList(),
        results: (j['results'] as List? ?? [])
            .map((e) => PaperResult.fromJson(e)).toList(),
      );

  bool get isTerminal =>
      status == '完成' || status == '处理失败' ||
      status == '部分完成' || status == '等待人工确认';
}
