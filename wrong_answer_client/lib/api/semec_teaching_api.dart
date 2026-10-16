// lib/api/semec_teaching_api.dart
// 与 semecTeaching 后端通信（JWT + CSRF 保护）

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:http_parser/http_parser.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/paper_models.dart';
import '../utils/app_navigator.dart';
import '../utils/server_config.dart';
import '../utils/theme.dart';
import '../screens/login_screen.dart';

// ── 常量 ─────────────────────────────────────────────────────────────────────
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

  const SemecLoginResult({required this.success, this.message, this.user});
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

  String _baseUrl = ServerConfig.instance.semecBaseUrl;
  String? _jwtToken;
  String? _csrfToken;
  SemecUser? _currentUser;

  /// 冷启动 token 读取完成信号：拦截登录前先 await，避免启动瞬间误判未登录
  final Completer<void> tokensReady = Completer<void>();

  /// 401 重新登录门：并发请求共享同一次登录流程，成功后由拦截器自动重放
  Completer<bool>? _reloginGate;

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
        if (jwt != null) {
          cookies.add('access_token=$jwt');
        }

        // 2. 附加 CSRF Cookie（后端双提交模式需要）
        final csrf = _csrfToken ?? await _storage.read(key: _kCsrfTokenKey);
        if (csrf != null) {
          cookies.add('XSRF-TOKEN=$csrf');
          // 同时附加到 header（双提交模式）
          options.headers['x-xsrf-token'] = csrf;
        }

        if (cookies.isNotEmpty) {
          options.headers['Cookie'] = cookies.join('; ');
        }
        handler.next(options);
      },
      onError: (error, handler) async {
        // 登录类接口的错误（如密码错误）由 login() 自行处理，不弹"过期"提示
        if (error.requestOptions.path.startsWith('/api/auth/')) {
          handler.next(error);
          return;
        }

        final status = error.response?.statusCode;
        if (status == 401) {
          // Token 过期：清登录态，挂起请求等用户重新登录；登录成功后自动重放
          // 原请求（批量并发共享同一次登录，只弹一次框），页面无需手动刷新
          await clearTokens();
          final reloggedIn = await _ensureRelogin();
          if (reloggedIn) {
            // FormData（上传/拍照订正）流只能消费一次，无法重放，交给用户重试
            if (error.requestOptions.data is FormData) {
              handler.reject(_friendly('登录已恢复，请重试刚才的操作', error));
              return;
            }
            try {
              // fetch 会重新经过 onRequest 拦截器，附加新的 JWT/CSRF
              final resp = await _dio.fetch(error.requestOptions);
              handler.resolve(resp);
            } catch (e) {
              handler.reject(e is DioException
                  ? e
                  : _friendly('服务暂时不可用，请稍后再试', error));
            }
            return;
          }
          handler.reject(_friendly('登录状态已过期，请重新登录', error));
          return;
        }
        if (status == 403) {
          handler.reject(_friendly('抱歉，你没有权限执行此操作', error));
          return;
        }

        String msg;
        switch (error.type) {
          case DioExceptionType.connectionTimeout:
          case DioExceptionType.sendTimeout:
          case DioExceptionType.receiveTimeout:
            msg = '网络连接超时，请稍后再试';
            break;
          case DioExceptionType.connectionError:
            msg = '无法连接服务器，请检查网络或服务器地址';
            break;
          case DioExceptionType.badCertificate:
            msg = '服务器安全验证失败，请联系老师';
            break;
          default:
            final data = error.response?.data;
            final serverMsg = data is Map
                ? (data['message'] ?? data['error'])?.toString()
                : null;
            // ponytail: 仅透传含中文的后端文案，英文/堆栈类技术信息一律不外显
            final readable = serverMsg != null &&
                RegExp(r'[一-鿿]').hasMatch(serverMsg);
            msg = readable ? serverMsg : '服务暂时不可用，请稍后再试';
        }
        handler.reject(_friendly(msg, error));
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
    try {
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
    } finally {
      // 无论读取成功与否都必须释放等待者（防永久挂起）
      if (!tokensReady.isCompleted) tokensReady.complete();
    }
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

  /// 把底层 DioException 转成只含友好文案的异常（$e 直接可见友好文本）
  DioException _friendly(String msg, DioException error) => _FriendlyException(
    msg,
    requestOptions: error.requestOptions,
    type: error.type,
    response: error.response,
  );

  /// 401 重新登录门：并发 401 共用同一个弹窗与结果，登录成功返回 true。
  /// 无可用 Navigator（如 App 启动早期）时直接失败，由页面走错误页重试。
  Future<bool> _ensureRelogin() {
    final gate = _reloginGate;
    if (gate != null) return gate.future;

    final completer = Completer<bool>();
    _reloginGate = completer;
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) {
      _reloginGate = null;
      return Future.value(false);
    }

    var navigating = false;
    showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: (dialogCtx) => PopScope(
        // 返回键关闭弹窗时必须释放等待队列，不能让并发请求永久挂起
        onPopInvokedWithResult: (didPop, _) {
          if (didPop && !navigating) _finishRelogin(false);
        },
        child: AlertDialog(
          title: const Row(children: [
            Icon(Icons.info_outline, size: 20, color: AppColors.amber),
            SizedBox(width: 8),
            Text('登录已过期'),
          ]),
          content: const Text('为了保证账号安全，请重新登录后再查看作业。'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogCtx).pop();
                _finishRelogin(false);
              },
              child: const Text('稍后'),
            ),
            ElevatedButton(
              onPressed: () async {
                navigating = true;
                Navigator.of(dialogCtx).pop();
                final ok =
                    await Navigator.of(ctx).push<bool>(MaterialPageRoute(
                  fullscreenDialog: true,
                  builder: (_) =>
                      const LoginScreen(reason: '登录状态已过期，请重新登录'),
                ));
                _finishRelogin(ok ?? false);
              },
              child: const Text('重新登录'),
            ),
          ],
        ),
      ),
    );
    return completer.future;
  }

  void _finishRelogin(bool ok) {
    final c = _reloginGate;
    _reloginGate = null;
    if (c != null && !c.isCompleted) c.complete(ok);
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
      // 登录接口 422 返回 {"error":"用户名或密码错误"}，字段名是 error；
      // 只外显中文文案，Dio 英文异常不外泄
      final data = e.response?.data;
      final serverMsg = data is Map
          ? (data['message'] ?? data['error'])?.toString()
          : null;
      final readable = serverMsg != null &&
          RegExp(r'[一-鿿]').hasMatch(serverMsg);
      return SemecLoginResult(
        success: false,
        message: readable
            ? serverMsg
            : (e.type == DioExceptionType.connectionError
                ? '无法连接服务器，请检查网络或服务器地址'
                : '登录失败，请检查账号或密码'),
      );
    } catch (_) {
      return const SemecLoginResult(
        success: false,
        message: '登录失败，请稍后再试',
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

  // ── 保存临时题目到 semecTeaching ──────────────────────────────────────────
  Future<SemecSaveResult> saveTempQuestion({
    required int authorId,
    required String subject,
    String? grade,
    required String content,
    String? answer,
    String? solution,
    List<String>? knowledgePoints,
    String? difficulty,
    String? imagePath,
    List<int>? studentIds,
    String? questionType,
  }) async {
    try {
      final resp = await _dio.post('/api/questions/temp', data: {
        'author_id': authorId,
        'subject': subject,
        'grade': grade,
        'content': content,
        'answer': answer,
        'solution': solution,
        'knowledge_point_ids': knowledgePoints,
        'difficulty': difficulty,
        'image_path': imagePath,
        'student_ids': studentIds,
        'question_type': questionType,
      });

      if (resp.statusCode == 200 && resp.data?['success'] == true) {
        final data = resp.data!['data'] as Map<String, dynamic>;
        return SemecSaveResult(
          success: true,
          incorrectId: data['question_id'] as int?,
        );
      }
      return SemecSaveResult(
        success: false,
        error: resp.data?['message'] ?? '保存失败',
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        return SemecSaveResult(
          success: false,
          error: '登录已过期，请重新登录',
        );
      }
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

  // ── 纸面作业判题链路（exam-server /api/answer/*，学生端）─────────────────

  /// 我的作业列表（GET /api/answer/papers/assignments）
  Future<List<PaperAssignment>> getPaperAssignments() async {
    final resp = await _dio.get('/api/answer/papers/assignments');
    if (resp.statusCode == 200 && resp.data?['success'] == true) {
      return (resp.data['data'] as List? ?? [])
          .map((e) => PaperAssignment.fromJson(
              Map<String, dynamic>.from(e)))
          .toList();
    }
    throw Exception(resp.data?['message'] ?? '获取作业列表失败');
  }

  /// 下载作业卷面 PDF（GET /api/assignments/:id/paper-pdf）
  /// 走同一 dio 实例以携带 JWT cookie；仅 homework 类型有入口（对齐网页端）
  Future<Uint8List> downloadAssignmentPdf(
    int assignId, {
    void Function(int received, int total)? onProgress,
  }) async {
    try {
      final resp = await _dio.get(
        '/api/assignments/$assignId/paper-pdf',
        options: Options(responseType: ResponseType.bytes),
        onReceiveProgress: onProgress,
      );
      if (resp.statusCode == 200) return resp.data as Uint8List;
      throw Exception('下载失败：HTTP ${resp.statusCode}');
    } on DioException catch (e) {
      // 错误响应是 JSON 但按 bytes 请求：解出后端中文文案（如"试卷文件尚未生成"）
      final data = e.response?.data;
      String? serverMsg;
      if (data is List<int>) {
        try {
          final j = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
          serverMsg = (j['message'] ?? j['error'])?.toString();
        } catch (_) {}
      }
      if (serverMsg != null) throw Exception(serverMsg);
      rethrow; // 401/403/网络错误已被拦截器转成友好文案
    }
  }

  /// 创建上传任务（POST /api/answer/uploads，multipart 字段名 files）
  Future<PaperUploadCreated> createPaperUpload(
    List<File> files, {
    int? assignId,
    void Function(int sent, int total)? onProgress,
  }) async {
    final parts = <MultipartFile>[];
    for (final f in files) {
      parts.add(await MultipartFile.fromFile(
        f.path,
        filename: f.path.split(Platform.pathSeparator).last,
      ));
    }
    final formData = FormData.fromMap({
      'files': parts,
      if (assignId != null) 'assign_id': '$assignId',
    });

    final resp = await _dio.post(
      '/api/answer/uploads',
      data: formData,
      onSendProgress: onProgress,
    );
    if (resp.statusCode == 200 && resp.data?['success'] == true) {
      return PaperUploadCreated.fromJson(
          Map<String, dynamic>.from(resp.data!['data']));
    }
    throw Exception(resp.data?['message'] ?? '上传失败');
  }

  /// 我的上传任务列表（GET /api/answer/uploads）
  Future<List<PaperUploadRow>> listPaperUploads({int page = 1}) async {
    final resp = await _dio.get('/api/answer/uploads',
        queryParameters: {'page': page});
    if (resp.statusCode == 200 && resp.data?['success'] == true) {
      final data = resp.data!['data'];
      return (data['list'] as List? ?? [])
          .map((e) => PaperUploadRow.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    throw Exception(resp.data?['message'] ?? '获取任务列表失败');
  }

  /// 单个上传任务详情（含 pages + results，GET /api/answer/uploads/:id）
  Future<PaperUploadDetail> getPaperUpload(int uploadId) async {
    final resp = await _dio.get('/api/answer/uploads/$uploadId');
    if (resp.statusCode == 200 && resp.data?['success'] == true) {
      return PaperUploadDetail.fromJson(
          Map<String, dynamic>.from(resp.data!['data']));
    }
    throw Exception(resp.data?['message'] ?? '获取任务详情失败');
  }

  /// 页图字节（GET /api/answer/pages/:pageId/image?type=original|normalized）
  /// normalized=批改标注图（坐标基准），original=学生原图
  Future<Uint8List> fetchPaperPageImage(int pageId,
      {String type = 'normalized'}) async {
    final resp = await _dio.get(
      '/api/answer/pages/$pageId/image',
      queryParameters: {'type': type},
      options: Options(responseType: ResponseType.bytes),
    );
    if (resp.statusCode == 200) {
      return resp.data as Uint8List;
    }
    throw Exception('获取页图片失败: HTTP ${resp.statusCode}');
  }

  /// 订正历史（GET /api/answer/results/:id/corrections，当前轮在前）
  Future<List<PaperCorrection>> getPaperCorrections(int resultId) async {
    final resp = await _dio.get('/api/answer/results/$resultId/corrections');
    if (resp.statusCode == 200 && resp.data?['success'] == true) {
      return (resp.data['data'] as List? ?? [])
          .map((e) => PaperCorrection.fromJson(
              Map<String, dynamic>.from(e)))
          .toList();
    }
    throw Exception(resp.data?['message'] ?? '获取订正记录失败');
  }

  /// 拍照订正（multipart POST 同 URL：file + error_tag_ids JSON 串）
  Future<CorrectionSubmitResult> submitPhotoPaperCorrection(
    int resultId,
    File file, {
    List<int> errorTagIds = const [],
  }) async {
    // 后端 correctionUpload 只收 image/*，按扩展名给准 MIME，避免落成 octet-stream
    final p = file.path.toLowerCase();
    final subtype = p.endsWith('.png') ? 'png'
        : p.endsWith('.webp') ? 'webp'
        : p.endsWith('.gif') ? 'gif' : 'jpeg';
    final formData = FormData.fromMap({
      'file': await MultipartFile.fromFile(
        file.path,
        filename: file.path.split(Platform.pathSeparator).last,
        contentType: MediaType('image', subtype),
      ),
      if (errorTagIds.isNotEmpty)
        'error_tag_ids': jsonEncode(errorTagIds),
    });
    final resp = await _dio.post(
      '/api/answer/results/$resultId/corrections',
      data: formData,
    );
    if (resp.statusCode == 200 && resp.data?['success'] == true) {
      return CorrectionSubmitResult.fromJson(
          Map<String, dynamic>.from(resp.data!['data']));
    }
    throw Exception(resp.data?['message'] ?? '订正提交失败');
  }

  /// 在线订正（JSON POST 同 URL）：channel=online，answer_payload 与考试 student_answer 同构
  /// 选择 {selectedAnswers:['B']} / 判断 true|false / 填空 {answers:['…']} / 文本 {text:'…'}
  Future<CorrectionSubmitResult> submitOnlinePaperCorrection(
    int resultId, {
    required Map<String, dynamic> answerPayload,
    List<int> errorTagIds = const [],
  }) async {
    final resp = await _dio.post(
      '/api/answer/results/$resultId/corrections',
      data: {
        'channel': 'online',
        'answer_payload': answerPayload,
        if (errorTagIds.isNotEmpty) 'error_tag_ids': errorTagIds,
      },
    );
    if (resp.statusCode == 200 && resp.data?['success'] == true) {
      return CorrectionSubmitResult.fromJson(
          Map<String, dynamic>.from(resp.data!['data']));
    }
    throw Exception(resp.data?['message'] ?? '订正提交失败');
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

/// toString 只输出友好文案，屏蔽 DioException 默认的技术性信息
class _FriendlyException extends DioException {
  _FriendlyException(
    String message, {
    required super.requestOptions,
    super.type,
    super.response,
  }) : super(message: message);

  @override
  String toString() => message ?? '网络异常，请稍后再试';
}
