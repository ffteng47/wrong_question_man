// lib/api/api_client.dart
import 'dart:io';
import 'package:dio/dio.dart';
import '../models/wrong_answer_record.dart';
import '../utils/theme.dart';

class ApiClient {
  static ApiClient? _instance;
  late final Dio _dio;

  ApiClient._() {
    _dio = Dio(BaseOptions(
      baseUrl: AppConst.baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 120), // 模型推理可能需要 2 分钟
      sendTimeout: const Duration(seconds: 30),
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
  Future<UploadResponse> uploadImage(
    File imageFile, {
    String imageSource = 'camera',
    void Function(int sent, int total)? onProgress,
  }) async {
    final formData = FormData.fromMap({
      'image': await MultipartFile.fromFile(
        imageFile.path,
        filename: imageFile.path.split('/').last,
      ),
      'image_source': imageSource,
    });

    final resp = await _dio.post(
      '/api/v1/upload',
      data: formData,
      onSendProgress: onProgress,
    );
    return UploadResponse.fromJson(resp.data as Map<String, dynamic>);
  }

  // ── POST /api/v1/extract ──────────────────────────────────────────────────
  Future<WrongAnswerRecord> extract({
    required String imageId,
    required List<double> roiBbox,
    String imageSource = 'camera',
    bool enableSemantic = false,
    void Function(String stage)? onStageChange,
  }) async {
    onStageChange?.call('OCR 识别中…');
    final resp = await _dio.post('/api/v1/extract', data: {
      'image_id': imageId,
      'roi_bbox': roiBbox,
      'image_source': imageSource,
      'enable_semantic': enableSemantic,
    });
    final data = resp.data as Map<String, dynamic>;
    return WrongAnswerRecord.fromJson(data['record'] as Map<String, dynamic>);
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
