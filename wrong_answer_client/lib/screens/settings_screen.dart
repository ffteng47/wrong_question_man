// lib/screens/settings_screen.dart
import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../api/semec_teaching_api.dart';
import '../services/sync_service.dart';
import '../utils/theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _urlCtrl = TextEditingController(text: AppConst.baseUrl);
  final _semecUrlCtrl = TextEditingController(text: SemecTeachingApi.instance.baseUrl);
  final _semecUserCtrl = TextEditingController();
  final _semecPassCtrl = TextEditingController();

  bool _testing = false;
  Map<String, dynamic>? _health;
  String? _error;

  bool _semecLoggingIn = false;
  String? _semecError;
  SemecUser? _semecUser;

  @override
  void initState() {
    super.initState();
    _loadSemecUser();
  }

  Future<void> _loadSemecUser() async {
    // 触发 token 加载（isLoggedIn getter 内部会异步加载，但返回值是 bool）
    SemecTeachingApi.instance.isLoggedIn;
    if (mounted) {
      setState(() {
        _semecUser = SyncService.instance.currentUser;
      });
    }
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _semecUrlCtrl.dispose();
    _semecUserCtrl.dispose();
    _semecPassCtrl.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    setState(() { _testing = true; _health = null; _error = null; });
    try {
      ApiClient.instance.setBaseUrl(_urlCtrl.text.trim());
      final h = await ApiClient.instance.health();
      if (mounted) setState(() { _health = h; _testing = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _testing = false; });
    }
  }

  // ── semecTeaching 登录 ──────────────────────────────────────────────────
  Future<void> _semecLogin() async {
    final username = _semecUserCtrl.text.trim();
    final password = _semecPassCtrl.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _semecError = '请输入用户名和密码');
      return;
    }

    setState(() { _semecLoggingIn = true; _semecError = null; });

    try {
      SemecTeachingApi.instance.setBaseUrl(_semecUrlCtrl.text.trim());
      final result = await SemecTeachingApi.instance.login(username, password);

      if (mounted) {
        setState(() {
          _semecLoggingIn = false;
          if (result.success) {
            _semecUser = result.user;
            _semecUserCtrl.clear();
            _semecPassCtrl.clear();
          } else {
            _semecError = result.message ?? '登录失败';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _semecLoggingIn = false;
          _semecError = e.toString();
        });
      }
    }
  }

  Future<void> _semecLogout() async {
    await SemecTeachingApi.instance.logout();
    if (mounted) setState(() => _semecUser = null);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg0,
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // ── OCR 服务器地址 ──────────────────────────────────────────────────
          const Text('OCR 服务器地址', style: AppText.label),
          const SizedBox(height: 8),
          TextField(
            controller: _urlCtrl,
            style: const TextStyle(
                color: AppColors.textPrimary, fontFamily: 'monospace'),
            decoration: const InputDecoration(
              hintText: 'http://192.168.x.x:9000',
              prefixIcon: Icon(Icons.dns_outlined,
                  size: 18, color: AppColors.textMuted),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _testing ? null : _testConnection,
              icon: _testing
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.bg0))
                  : const Icon(Icons.wifi_find_outlined, size: 18),
              label: Text(_testing ? '测试中…' : '测试连接'),
            ),
          ),

          // ── 健康状态 ───────────────────────────────────────────────────────
          if (_health != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.bg1,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.bg3),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _healthRow('FastAPI 中间层',
                      true, Icons.check_circle_outline),
                  _healthRow('MinerU OCR',
                      _health!['mineru_ok'] == true,
                      Icons.document_scanner_outlined),
                  _healthRow('Qwen vLLM',
                      _health!['qwen_ok'] == true,
                      Icons.psychology_outlined),
                  _healthRow('本地存储',
                      _health!['storage_ok'] == true,
                      Icons.folder_outlined),
                ],
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.red.withOpacity(0.3)),
              ),
              child: Text(_error!,
                  style: const TextStyle(
                      color: AppColors.red, fontSize: 12, fontFamily: 'monospace')),
            ),
          ],

          const SizedBox(height: 32),
          const Divider(),
          const SizedBox(height: 16),

          // ── semecTeaching 云端同步 ─────────────────────────────────────────
          Row(
            children: [
              const Text('semecTeaching 云端同步', style: AppText.label),
              const Spacer(),
              if (_semecUser != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.green.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '已登录: ${_semecUser!.realName.isNotEmpty ? _semecUser!.realName : _semecUser!.username}',
                    style: const TextStyle(
                        color: AppColors.green, fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),

          // 服务器地址
          TextField(
            controller: _semecUrlCtrl,
            style: const TextStyle(
                color: AppColors.textPrimary, fontFamily: 'monospace', fontSize: 13),
            decoration: const InputDecoration(
              hintText: 'http://192.168.x.x:3000',
              prefixIcon: Icon(Icons.cloud_outlined,
                  size: 18, color: AppColors.textMuted),
              labelText: '服务器地址',
              labelStyle: TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(height: 12),

          // 登录表单或已登录信息
          if (_semecUser == null) ...[
            TextField(
              controller: _semecUserCtrl,
              style: const TextStyle(
                  color: AppColors.textPrimary, fontSize: 14),
              decoration: const InputDecoration(
                hintText: '用户名',
                prefixIcon: Icon(Icons.person_outline,
                    size: 18, color: AppColors.textMuted),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _semecPassCtrl,
              obscureText: true,
              style: const TextStyle(
                  color: AppColors.textPrimary, fontSize: 14),
              decoration: const InputDecoration(
                hintText: '密码',
                prefixIcon: Icon(Icons.lock_outline,
                    size: 18, color: AppColors.textMuted),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _semecLoggingIn ? null : _semecLogin,
                icon: _semecLoggingIn
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: AppColors.bg0))
                    : const Icon(Icons.login, size: 18),
                label: Text(_semecLoggingIn ? '登录中…' : '登录'),
              ),
            ),
          ] else ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.bg1,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.bg3),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _infoRow('用户', _semecUser!.username),
                  _infoRow('姓名', _semecUser!.realName),
                  _infoRow('角色', _semecUser!.role),
                  _infoRow('ID', '${_semecUser!.id}'),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _semecLogout,
                icon: const Icon(Icons.logout, size: 18, color: AppColors.red),
                label: const Text('退出登录',
                    style: TextStyle(color: AppColors.red)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: AppColors.red),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],

          if (_semecError != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.red.withOpacity(0.3)),
              ),
              child: Text(_semecError!,
                  style: const TextStyle(
                      color: AppColors.red, fontSize: 12)),
            ),
          ],

          const SizedBox(height: 32),
          const Divider(),
          const SizedBox(height: 16),

          // ── 关于 ──────────────────────────────────────────────────────────
          const Text('关于', style: AppText.label),
          const SizedBox(height: 12),
          _infoRow('版本', '1.0.0'),
          _infoRow('模型', 'Qwen2.5-VL-7B-AWQ + MinerU2.5-Pro'),
          _infoRow('部署', '纯本地，RTX 3090 24GB'),
        ],
      ),
    );
  }

  Widget _healthRow(String label, bool ok, IconData icon) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(children: [
      Icon(icon, size: 16, color: ok ? AppColors.green : AppColors.textMuted),
      const SizedBox(width: 10),
      Text(label, style: const TextStyle(
          color: AppColors.textSecondary, fontSize: 13)),
      const Spacer(),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: (ok ? AppColors.green : AppColors.textMuted).withOpacity(0.15),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(ok ? 'OK' : '离线',
            style: TextStyle(
                color: ok ? AppColors.green : AppColors.textMuted,
                fontSize: 11, fontWeight: FontWeight.w600)),
      ),
    ]),
  );

  Widget _infoRow(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(children: [
      SizedBox(width: 60,
          child: Text(k, style: AppText.label)),
      Expanded(child: Text(v,
          style: const TextStyle(
              color: AppColors.textSecondary, fontSize: 13))),
    ]),
  );
}
