// lib/api/api_client.dart
//
// wrong_answer_server（错题链路中间层）客户端
// 服务端为异步任务制：upload/extract 返回 task_id，轮询 /api/v1/tasks/{id} 拿结果
import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import '../models/wrong_answer_record.dart';
import '../utils/server_config.dart';

class TaskFailedException implements Exception {
  final String message;
  TaskFailedException(this.message);
  @override
  String toString() => message;
}

class ApiClient {
  static ApiClient? _instance;
  late final Dio _dio;

  ApiClient._() {
    _dio = Dio(BaseOptions(
      baseUrl: ServerConfig.instance.apiBaseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 60),
    ));

    if (const bool.fromEnvironment('dart.vm.product') == false) {
      _dio.interceptors.add(LogInterceptor(
        requestBody: false,
        responseBody: true,
        logPrint: (o) => print('[API] $o'),
      ));
    }
  }

  static ApiClient get instance => _instance ??= ApiClient._();

  // 动态切换服务器地址（设置页使用）
  void setBaseUrl(String url) => _dio.options.baseUrl = url;

  // ── /health ────────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> health() async {
    final resp = await _dio.get('/health');
    return resp.data as Map<String, dynamic>;
  }

  // ── POST /api/v1/upload ───────────────────────────────────────────────────
  /// 返回 {image_id, task_id}；解析结果由 pollTask 获取
  Future<Map<String, dynamic>> uploadImage(
    File imageFile, {
    String imageSource = 'camera',
    void Function(int sent, int total)? onProgress,
  }) async {
    final formData = FormData.fromMap({
      'image': await MultipartFile.fromFile(
        imageFile.path,
        filename: imageFile.path.split(Platform.pathSeparator).last,
      ),
      'image_source': imageSource,
    });

    final resp = await _dio.post(
      '/api/v1/upload',
      data: formData,
      onSendProgress: onProgress,
    );
    return resp.data as Map<String, dynamic>;
  }

  /// 上传 + 轮询解析任务，一步拿到 UploadResponse
  Future<UploadResponse> uploadAndParse(
    File imageFile, {
    String imageSource = 'camera',
    void Function(int sent, int total)? onProgress,
  }) async {
    final accepted =
        await uploadImage(imageFile, imageSource: imageSource, onProgress: onProgress);
    final taskId = accepted['task_id'] as String;
    final result = await pollTask(taskId);
    return UploadResponse.fromJson(result);
  }

  // ── POST /api/v1/extract ──────────────────────────────────────────────────
  /// roiBbox / answerBbox 均为 0~1000 归一化坐标
  Future<WrongAnswerRecord> extract({
    required String imageId,
    required List<double> roiBbox,
    List<double>? answerBbox,
    String imageSource = 'camera',
    bool enableSemantic = true,
    void Function(String stage)? onStageChange,
  }) async {
    onStageChange?.call('创建识别任务…');
    final resp = await _dio.post('/api/v1/extract', data: {
      'image_id': imageId,
      'question_region': {'bbox': roiBbox, 'coord_space': '0_1000'},
      if (answerBbox != null)
        'answer_region': {'bbox': answerBbox, 'coord_space': '0_1000'},
      'image_source': imageSource,
      'enable_semantic': enableSemantic,
    });
    final taskId = (resp.data as Map<String, dynamic>)['task_id'] as String;

    onStageChange?.call('OCR 识别中…');
    final result = await pollTask(
      taskId,
      onProcessing: () => onStageChange?.call('OCR + 语义分析中…'),
    );
    return WrongAnswerRecord.fromJson(
        result['record'] as Map<String, dynamic>);
  }

  // ── GET /api/v1/tasks/{id} 轮询 ───────────────────────────────────────────
  /// 轮询直到 done（返回 result）或 failed/超时（抛异常）
  Future<Map<String, dynamic>> pollTask(
    String taskId, {
    Duration interval = const Duration(seconds: 2),
    Duration timeout = const Duration(minutes: 5),
    void Function()? onProcessing,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final resp = await _dio.get('/api/v1/tasks/$taskId');
      final task = resp.data as Map<String, dynamic>;
      switch (task['status']) {
        case 'done':
          return Map<String, dynamic>.from(task['result'] as Map);
        case 'failed':
          throw TaskFailedException(
              (task['error'] ?? '识别任务失败').toString());
        default:
          onProcessing?.call();
          await Future.delayed(interval);
      }
    }
    throw TimeoutException('识别任务超时: $taskId');
  }

  // ── POST /api/v1/save ─────────────────────────────────────────────────────
  Future<String> saveRecord(WrongAnswerRecord record) async {
    final resp = await _dio.post('/api/v1/save', data: {
      'record': record.toJson(),
    });
    return (resp.data as Map<String, dynamic>)['id'] as String;
  }

  // ── GET /api/v1/records ───────────────────────────────────────────────────
  Future<List<WrongAnswerRecord>> listRecords({
    String? subject,
    String? grade,
    String? reviewStatus,
    int limit = 50,
    int offset = 0,
  }) async {
    final resp = await _dio.get('/api/v1/records', queryParameters: {
      if (subject != null) 'subject': subject,
      if (grade != null) 'grade': grade,
      if (reviewStatus != null) 'review_status': reviewStatus,
      'limit': limit,
      'offset': offset,
    });
    return (resp.data as List)
        .map((e) => WrongAnswerRecord.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ── DELETE /api/v1/records/{id} ───────────────────────────────────────────
  Future<void> deleteRecord(String id) async {
    await _dio.delete('/api/v1/records/$id');
  }
}
