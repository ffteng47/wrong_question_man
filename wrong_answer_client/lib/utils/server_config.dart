// lib/utils/server_config.dart
//
// 服务器地址配置：默认值可用 --dart-define 覆盖，设置页修改后持久化生效
//   flutter build apk --dart-define=WQM_API_BASE=http://<中间层主机>:9000 \
//                    --dart-define=SEMEC_API_BASE=http://<判题后端主机>:3000
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../api/api_client.dart';
import '../api/semec_teaching_api.dart';

const _kDefaultApiBase =
    String.fromEnvironment('WQM_API_BASE', defaultValue: 'http://192.168.41.177:9000');
const _kDefaultSemecBase =
    String.fromEnvironment('SEMEC_API_BASE', defaultValue: 'http://192.168.41.138:3000');

class ServerConfig {
  static final ServerConfig instance = ServerConfig._();
  ServerConfig._();

  static const _kApiBaseKey = 'wqm_api_base_url';
  static const _kSemecBaseKey = 'semec_base_url';
  final _storage = const FlutterSecureStorage();

  String apiBaseUrl = _kDefaultApiBase;
  String semecBaseUrl = _kDefaultSemecBase;

  /// 启动时调用：读取持久化地址并应用到两个 API 客户端
  Future<void> loadAndApply() async {
    apiBaseUrl = await _storage.read(key: _kApiBaseKey) ?? apiBaseUrl;
    semecBaseUrl = await _storage.read(key: _kSemecBaseKey) ?? semecBaseUrl;
    ApiClient.instance.setBaseUrl(apiBaseUrl);
    SemecTeachingApi.instance.setBaseUrl(semecBaseUrl);
  }

  Future<void> setApiBaseUrl(String url) async {
    apiBaseUrl = url.trim();
    await _storage.write(key: _kApiBaseKey, value: apiBaseUrl);
    ApiClient.instance.setBaseUrl(apiBaseUrl);
  }

  Future<void> setSemecBaseUrl(String url) async {
    semecBaseUrl = url.trim();
    await _storage.write(key: _kSemecBaseKey, value: semecBaseUrl);
    SemecTeachingApi.instance.setBaseUrl(semecBaseUrl);
  }
}
