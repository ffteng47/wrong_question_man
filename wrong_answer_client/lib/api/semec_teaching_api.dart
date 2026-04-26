// lib/api/semec_teaching_api.dart
// 与 semecTeaching 后端通信（JWT + CSRF 保护）

import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// ── 常量 ─────────────────────────────────────────────────────────────────────
const String _kSemecBaseUrl = 'http://192.168.41.138:3000';
const String _kJwtTokenKey = 'semec_access_token';
const String _kCsrfTokenKey = 'semec_csrf_token';
const String _kSemecUserKey = 'semec_user_json';

// ── 模型 ─────────────────────────────────────────────────────────────────────
class SemecUser {
  final int id;
  final String username;
  final String role;
  final String realName;

  SemecUser({
    required this.id,
    required this.username,
    required this.role,
    required this.realName,
  });

  factory SemecUser.fromJson(Map<String, dynamic> j) => SemecUser(
        id: j['id'] ?? 0,
        username: j['username'] ?? '',
        role: j['role'] ?? '',
        realName: j['realName'] ?? j['real_name'] ?? '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'role': role,
        'real_name': realName,
      };
}

class SemecLoginResult {
  final bool success;
  final String? message;
  final SemecUser? user;

  SemecLoginResult({required this.success, this.message, this.user});
}

class SemecUploadResult {
  final bool success;
  final String? url;
  final String? filename;
  final String? error;

  SemecUploadResult({required this.success, this.url, this.filename, this.error});
}

class SemecSaveResult {
  final bool success;
  final int? incorrectId;
  final String? error;

  SemecSaveResult({required this.success, this.incorrectId, this.error});
}

// ── API Client ───────────────────────────────────────────────────────────────
class SemecTeachingApi {
  static SemecTeachingApi? _instance;
  late final Dio _dio;
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  String _baseUrl = _kSemecBaseUrl;
  String? _jwtToken;
  String? _csrfToken;
  SemecUser? _currentUser;

  SemecTeachingApi._() {
    _dio = Dio(BaseOptions(
      baseUrl: _baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 60),
      sendTimeout: const Duration(seconds: 30),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
    ));

    // 允许自签名证书（开发环境）
    (_dio.httpClientAdapter as IOHttpClientAdapter).onHttpClientCreate =
        (client) {
      client.badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
      return client;
    };

    // 请求拦截器：自动附加 JWT Cookie + CSRF header
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        final cookies = <String>[];

        // 1. 附加 JWT Cookie（Dio 默认不自动携带）
        final jwt = _jwtToken ?? await _storage.read(key: _kJwtTokenKey);
        print('[SEMEC_DEBUG] jwt is null: ${jwt == null}, length: ${jwt?.length ?? 0}');
        if (jwt != null) {
          cookies.add('access_token=$jwt');
        }

        // 2. 附加 CSRF Cookie（后端双提交模式需要）
        final csrf = _csrfToken ?? await _storage.read(key: _kCsrfTokenKey);
        print('[SEMEC_DEBUG] csrf is null: ${csrf == null}, length: ${csrf?.length ?? 0}');
        if (csrf != null) {
          cookies.add('XSRF-TOKEN=$csrf');
          // 同时附加到 header（双提交模式）
          options.headers['x-xsrf-token'] = csrf;
        }

        if (cookies.isNotEmpty) {
          options.headers['Cookie'] = cookies.join('; ');
        }
        print('[SEMEC_DEBUG] cookies list: $cookies');
        print('[SEMEC_DEBUG] Cookie header: ${options.headers['Cookie']}');
        print('[SEMEC_DEBUG] x-xsrf-token header: ${options.headers['x-xsrf-token']}');
        print('[SEMEC_DEBUG] all headers: ${options.headers}');
        handler.next(options);
      },
      onError: (error, handler) async {
        if (error.response?.statusCode == 401 ||
            error.response?.statusCode == 403) {
          final errMsg = error.response?.data?['error']?.toString() ?? '';
          if (errMsg.contains('token') || errMsg.contains('CSRF')) {
            // Token 可能过期，但保留用户状态，让调用方决定重试
          }
        }
        handler.next(error);
      },
    ));

    if (const bool.fromEnvironment('dart.vm.product') == false) {
      _dio.interceptors.add(LogInterceptor(
        requestBody: true,
        responseBody: true,
        logPrint: (o) => print('[SEMEC] $o'),
      ));
    }

    // 启动时加载缓存的 token
    _loadTokens();
  }

  static SemecTeachingApi get instance => _instance ??= SemecTeachingApi._();

  // ── 配置 ──────────────────────────────────────────────────────────────────
  String get baseUrl => _baseUrl;

  void setBaseUrl(String url) {
    _baseUrl = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    _dio.options.baseUrl = _baseUrl;
  }

  SemecUser? get currentUser => _currentUser;

  bool get isLoggedIn => _jwtToken != null && _currentUser != null;

  // ── Token 管理（SecureStorage）────────────────────────────────────────────
  Future<void> _loadTokens() async {
    _jwtToken = await _storage.read(key: _kJwtTokenKey);
    _csrfToken = await _storage.read(key: _kCsrfTokenKey);
    final userJson = await _storage.read(key: _kSemecUserKey);
    if (userJson != null && userJson.isNotEmpty) {
      try {
        // 尝试解析为简单格式 id|username|role|realName
        final parts = userJson.split('|');
        if (parts.length >= 4) {
          _currentUser = SemecUser(
            id: int.tryParse(parts[0]) ?? 0,
            username: parts[1],
            role: parts[2],
            realName: parts[3],
          );
        }
      } catch (_) {}
    }
  }

  Future<String?> _getCsrfToken() async {
    if (_csrfToken != null) return _csrfToken;
    _csrfToken = await _storage.read(key: _kCsrfTokenKey);
    return _csrfToken;
  }

  Future<void> _saveTokens({
    String? jwt,
    String? csrf,
    SemecUser? user,
  }) async {
    if (jwt != null) {
      _jwtToken = jwt;
      await _storage.write(key: _kJwtTokenKey, value: jwt);
    }
    if (csrf != null) {
      _csrfToken = csrf;
      await _storage.write(key: _kCsrfTokenKey, value: csrf);
    }
    if (user != null) {
      _currentUser = user;
      // 简单格式存储，避免 JSON 序列化问题
      await _storage.write(
        key: _kSemecUserKey,
        value: '${user.id}|${user.username}|${user.role}|${user.realName}',
      );
    }
  }

  Future<void> clearTokens() async {
    _jwtToken = null;
    _csrfToken = null;
    _currentUser = null;
    await _storage.delete(key: _kJwtTokenKey);
    await _storage.delete(key: _kCsrfTokenKey);
    await _storage.delete(key: _kSemecUserKey);
  }

  // ── 登录 ──────────────────────────────────────────────────────────────────
  /// 登录 semecTeaching，获取 JWT 和 CSRF token
  Future<SemecLoginResult> login(String username, String password) async {
    try {
      // 1. 登录获取 JWT（cookie 形式）
      final loginResp = await _dio.post(
        '/api/auth/login',
        data: {'username': username, 'password': password},
      );

      if (loginResp.statusCode != 200) {
        return SemecLoginResult(
          success: false,
          message: loginResp.data?['message'] ?? '登录失败',
        );
      }

      // 从响应 cookies 中提取 access_token
      final cookies = loginResp.headers['set-cookie'];
      String? accessToken;
      String? refreshToken;
      if (cookies != null) {
        for (final cookie in cookies) {
          if (cookie.startsWith('access_token=')) {
            accessToken = cookie.split(';').first.replaceFirst('access_token=', '');
          }
          if (cookie.startsWith('refresh_token=')) {
            refreshToken = cookie.split(';').first.replaceFirst('refresh_token=', '');
          }
        }
      }

      if (accessToken == null) {
        return SemecLoginResult(
          success: false,
          message: '服务器未返回 Token',
        );
      }

      // 2. 解析 JWT payload 获取用户信息
      final user = _parseJwt(accessToken);
      if (user == null) {
        return SemecLoginResult(
          success: false,
          message: 'Token 解析失败',
        );
      }

      // 3. 获取 CSRF token
      final csrfResp = await _dio.get(
        '/api/auth/csrf-init',
        options: Options(
          headers: {
            'Cookie': 'access_token=$accessToken;refresh_token=$refreshToken',
          },
        ),
      );

      String? csrfToken;
      final csrfCookies = csrfResp.headers['set-cookie'];
      if (csrfCookies != null) {
        for (final cookie in csrfCookies) {
          if (cookie.startsWith('XSRF-TOKEN=')) {
            csrfToken = cookie.split(';').first.replaceFirst('XSRF-TOKEN=', '');
          }
        }
      }

      // 4. 保存所有 token
      await _saveTokens(
        jwt: accessToken,
        csrf: csrfToken,
        user: user,
      );

      return SemecLoginResult(
        success: true,
        user: user,
      );
    } on DioException catch (e) {
      return SemecLoginResult(
        success: false,
        message: e.response?.data?['message'] ?? e.message ?? '网络错误',
      );
    } catch (e) {
      return SemecLoginResult(
        success: false,
        message: e.toString(),
      );
    }
  }

  // ── 登出 ──────────────────────────────────────────────────────────────────
  Future<void> logout() async {
    try {
      await _dio.post('/api/auth/logout');
    } catch (_) {}
    await clearTokens();
  }

  // ── 图片上传 ──────────────────────────────────────────────────────────────
  /// 上传图片到 semecTeaching /api/upload/image
  Future<SemecUploadResult> uploadImage(File imageFile) async {
    try {
      final formData = FormData.fromMap({
        'file': await MultipartFile.fromFile(
          imageFile.path,
          filename: imageFile.path.split(Platform.pathSeparator).last,
        ),
      });

      final resp = await _dio.post(
        '/api/upload/image',
        data: formData,
        options: Options(
          headers: {
            'Content-Type': 'multipart/form-data',
          },
        ),
      );

      if (resp.statusCode == 200 && resp.data?['success'] == true) {
        final data = resp.data!['data'] as Map<String, dynamic>;
        return SemecUploadResult(
          success: true,
          url: data['url'] as String?,
          filename: data['filename'] as String?,
        );
      }
      return SemecUploadResult(
        success: false,
        error: resp.data?['message'] ?? '上传失败',
      );
    } on DioException catch (e) {
      return SemecUploadResult(
        success: false,
        error: e.response?.data?['message'] ?? e.message ?? '网络错误',
      );
    } catch (e) {
      return SemecUploadResult(success: false, error: e.toString());
    }
  }

  // ── 保存错题 ──────────────────────────────────────────────────────────────
  /// 将纸质错题保存到 semecTeaching
  Future<SemecSaveResult> saveIncorrectQuestion({
    required int userId,
    required String subject,
    required String problem,
    String? grade,
    List<String>? knowledgePoints,
    String? answer,
    String? solution,
    String? studentAnswer,
    String? errorCategory,
    String? errorDesc,
    List<String>? images,
    int? difficulty,
    double? realScore,
  }) async {
    try {
      final resp = await _dio.post(
        '/api/incorrect/from-wrong-question-man',
        data: {
          'user_id': userId,
          'subject': subject,
          'problem': problem,
          if (grade != null) 'grade': grade,
          if (knowledgePoints != null) 'knowledge_points': knowledgePoints,
          if (answer != null) 'answer': answer,
          if (solution != null) 'solution': solution,
          if (studentAnswer != null) 'student_answer': studentAnswer,
          if (errorCategory != null) 'error_category': errorCategory,
          if (errorDesc != null) 'error_desc': errorDesc,
          if (images != null && images.isNotEmpty) 'images': images,
          if (difficulty != null) 'difficulty': difficulty,
          if (realScore != null) 'real_score': realScore,
        },
      );

      if (resp.statusCode == 200 && resp.data?['success'] == true) {
        final data = resp.data!['data'] as Map<String, dynamic>;
        return SemecSaveResult(
          success: true,
          incorrectId: data['incorrect_id'] as int?,
        );
      }
      return SemecSaveResult(
        success: false,
        error: resp.data?['message'] ?? '保存失败',
      );
    } on DioException catch (e) {
      return SemecSaveResult(
        success: false,
        error: e.response?.data?['message'] ?? e.message ?? '网络错误',
      );
    } catch (e) {
      return SemecSaveResult(success: false, error: e.toString());
    }
  }

  // ── 获取班级树（含学生列表）──────────────────────────────────────────────
  /// 复用 POST /classes/class-tree，教师角色自动过滤自己班级
  Future<List<Map<String, dynamic>>> getClassTree() async {
    try {
      final resp = await _dio.post('/api/classes/class-tree');
      if (resp.statusCode == 200 && resp.data?['code'] == 0) {
        return List<Map<String, dynamic>>.from(resp.data!['data'] ?? []);
      }
      return [];
    } on DioException catch (e) {
      print('[SEMEC] 获取班级树失败: ${e.response?.data?['message'] ?? e.message}');
      return [];
    } catch (e) {
      print('[SEMEC] 获取班级树失败: $e');
      return [];
    }
  }

  // ── 工具方法 ──────────────────────────────────────────────────────────────
  SemecUser? _parseJwt(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;

      String normalize(String s) {
        final padding = 4 - s.length % 4;
        if (padding != 4) s += '=' * padding;
        return s.replaceAll('-', '+').replaceAll('_', '/');
      }

      final payload =
          utf8.decode(base64Url.decode(normalize(parts[1])));
      final json = Map<String, dynamic>.from(
          const JsonDecoder().convert(payload));

      return SemecUser.fromJson(json);
    } catch (_) {
      return null;
    }
  }
}
