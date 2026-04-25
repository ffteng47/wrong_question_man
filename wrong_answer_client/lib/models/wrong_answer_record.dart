// lib/models/wrong_answer_record.dart
import 'dart:convert';

// ── Asset ────────────────────────────────────────────────────────────────────
class Asset {
  final String id;
  final String srcPath;
  final List<double> bboxInOriginal;
  final String caption;
  final String markdownRef;

  Asset({
    required this.id,
    required this.srcPath,
    this.bboxInOriginal = const [],
    this.caption = '',
    this.markdownRef = '',
  });

  factory Asset.fromJson(Map<String, dynamic> j) => Asset(
    id: j['id'] ?? '',
    srcPath: j['src_path'] ?? '',
    bboxInOriginal: (j['bbox_in_original'] as List?)
        ?.map((e) => (e as num).toDouble()).toList() ?? [],
    caption: j['caption'] ?? '',
    markdownRef: j['markdown_ref'] ?? '',
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'src_path': srcPath,
    'bbox_in_original': bboxInOriginal,
    'caption': caption,
    'markdown_ref': markdownRef,
  };
}

// ── ErrorAnalysis ─────────────────────────────────────────────────────────────
class ErrorAnalysis {
  String studentAnswer;
  String errorCategory;
  String errorDesc;
  String preventionTip;

  ErrorAnalysis({
    this.studentAnswer = '',
    this.errorCategory = '未知',
    this.errorDesc = '',
    this.preventionTip = '',
  });

  factory ErrorAnalysis.fromJson(Map<String, dynamic> j) => ErrorAnalysis(
    studentAnswer: j['student_answer'] ?? '',
    errorCategory: j['error_category'] ?? '未知',
    errorDesc: j['error_desc'] ?? '',
    preventionTip: j['prevention_tip'] ?? '',
  );

  Map<String, dynamic> toJson() => {
    'student_answer': studentAnswer,
    'error_category': errorCategory,
    'error_desc': errorDesc,
    'prevention_tip': preventionTip,
  };
}

// ── UserSelection ─────────────────────────────────────────────────────────────
class UserSelection {
  final List<double> roiBbox;

  UserSelection({required this.roiBbox});

  factory UserSelection.fromJson(Map<String, dynamic> j) => UserSelection(
    roiBbox: (j['roi_bbox'] as List?)
        ?.map((e) => (e as num).toDouble()).toList() ?? [],
  );

  Map<String, dynamic> toJson() => {'roi_bbox': roiBbox};
}

class Source {
  final String imagePath;
  final String imageSource;
  final UserSelection? userSelection;

  Source({
    required this.imagePath,
    this.imageSource = 'camera',
    this.userSelection,
  });

  factory Source.fromJson(Map<String, dynamic> j) => Source(
    imagePath: j['image_path'] ?? '',
    imageSource: j['image_source'] ?? 'camera',
    userSelection: j['user_selection'] != null
        ? UserSelection.fromJson(j['user_selection']) : null,
  );

  Map<String, dynamic> toJson() => {
    'image_path': imagePath,
    'image_source': imageSource,
    if (userSelection != null) 'user_selection': userSelection!.toJson(),
  };
}

// ── WrongAnswerRecord ─────────────────────────────────────────────────────────
class WrongAnswerRecord {
  String id;
  String createdAt;
  String updatedAt;
  Source source;

  String type;
  int? seq;
  String? subSeq;

  String problem;
  String answer;
  String solution;

  List<Asset> assets;

  String subject;
  String grade;
  List<String> chapters;
  List<String> knowledgePoints;
  List<String> keyPoints;

  double realScore;
  int difficulty;
  String difficultyDesc;

  ErrorAnalysis errorAnalysis;

  String reviewStatus;
  List<String> tags;

  WrongAnswerRecord({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    required this.source,
    this.type = '未知',
    this.seq,
    this.subSeq,
    this.problem = '',
    this.answer = '',
    this.solution = '',
    this.assets = const [],
    this.subject = '未知',
    this.grade = '未知',
    this.chapters = const [],
    this.knowledgePoints = const [],
    this.keyPoints = const [],
    this.realScore = 0,
    this.difficulty = 3,
    this.difficultyDesc = '',
    ErrorAnalysis? errorAnalysis,
    this.reviewStatus = 'pending',
    this.tags = const [],
  }) : errorAnalysis = errorAnalysis ?? ErrorAnalysis();

  factory WrongAnswerRecord.fromJson(Map<String, dynamic> j) => WrongAnswerRecord(
    id: j['id'] ?? '',
    createdAt: j['created_at'] ?? '',
    updatedAt: j['updated_at'] ?? '',
    source: Source.fromJson(j['source'] ?? {}),
    type: j['type'] ?? '未知',
    seq: j['seq'],
    subSeq: j['sub_seq'],
    problem: j['problem'] ?? '',
    answer: j['answer'] ?? '',
    solution: j['solution'] ?? '',
    assets: (j['assets'] as List?)
        ?.map((e) => Asset.fromJson(e)).toList() ?? [],
    subject: j['subject'] ?? '未知',
    grade: j['grade'] ?? '未知',
    chapters: List<String>.from(j['chapters'] ?? []),
    knowledgePoints: List<String>.from(j['knowledge_points'] ?? []),
    keyPoints: List<String>.from(j['key_points'] ?? []),
    realScore: (j['real_score'] as num?)?.toDouble() ?? 0,
    difficulty: j['difficulty'] ?? 3,
    difficultyDesc: j['difficulty_desc'] ?? '',
    errorAnalysis: ErrorAnalysis.fromJson(j['error_analysis'] ?? {}),
    reviewStatus: j['review_status'] ?? 'pending',
    tags: List<String>.from(j['tags'] ?? []),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'source': source.toJson(),
    'type': type,
    'seq': seq,
    'sub_seq': subSeq,
    'problem': problem,
    'answer': answer,
    'solution': solution,
    'assets': assets.map((a) => a.toJson()).toList(),
    'subject': subject,
    'grade': grade,
    'chapters': chapters,
    'knowledge_points': knowledgePoints,
    'key_points': keyPoints,
    'real_score': realScore,
    'difficulty': difficulty,
    'difficulty_desc': difficultyDesc,
    'error_analysis': errorAnalysis.toJson(),
    'review_status': reviewStatus,
    'tags': tags,
  };

  String toJsonString() => jsonEncode(toJson());
}

// ── ContentBlock（上传预览用）────────────────────────────────────────────────
class ContentBlock {
  final String id;
  final String type;
  final List<double> bbox;

  ContentBlock({required this.id, required this.type, required this.bbox});

  factory ContentBlock.fromJson(Map<String, dynamic> j) => ContentBlock(
    id: j['id'] ?? '',
    type: j['type'] ?? 'text',
    bbox: (j['bbox'] as List?)
        ?.map((e) => (e as num).toDouble()).toList() ?? [],
  );
}

// ── UploadResponse ────────────────────────────────────────────────────────────
class UploadResponse {
  final String imageId;
  final int widthPx;
  final int heightPx;
  final List<ContentBlock> previewBlocks;

  UploadResponse({
    required this.imageId,
    required this.widthPx,
    required this.heightPx,
    required this.previewBlocks,
  });

  factory UploadResponse.fromJson(Map<String, dynamic> j) => UploadResponse(
    imageId: j['image_id'] ?? '',
    widthPx: j['width_px'] ?? 0,
    heightPx: j['height_px'] ?? 0,
    previewBlocks: (j['preview_blocks'] as List?)
        ?.map((e) => ContentBlock.fromJson(e)).toList() ?? [],
  );
}
