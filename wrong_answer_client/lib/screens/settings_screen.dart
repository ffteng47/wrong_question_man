// lib/screens/settings_screen.dart
import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../api/semec_teaching_api.dart';
import '../services/sync_service.dart';
import '../utils/server_config.dart';
import '../utils/theme.dart';
import 'login_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _urlCtrl = TextEditingController(text: ServerConfig.instance.apiBaseUrl);

  bool _testing = false;
  Map<String, dynamic>? _health;
  String? _error;

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
    super.dispose();
  }

  Future<void> _testConnection() async {
    setState(() { _testing = true; _health = null; _error = null; });
    try {
      await ServerConfig.instance.setApiBaseUrl(_urlCtrl.text.trim());
      final h = await ApiClient.instance.health();
      if (mounted) setState(() { _health = h; _testing = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _testing = false; });
    }
  }

  // ── semecTeaching 登录（跳转专用登录页，返回后刷新账号状态）──────────────
  Future<void> _openLogin() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const LoginScreen(),
      ),
    );
    if (ok == true && mounted) {
      setState(() => _semecUser = SyncService.instance.currentUser);
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

          // 账号卡片：未登录 → 去专用登录页；已登录 → 账号信息 + 退出
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.bg1,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.bg3),
            ),
            child: _semecUser == null
                ? Row(children: [
                    Container(
                      width: 38, height: 38,
                      decoration: BoxDecoration(
                        color: AppColors.bg2,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: AppColors.bg3),
                      ),
                      child: const Icon(Icons.person_outline,
                          size: 20, color: AppColors.textMuted),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('未登录',
                              style: TextStyle(
                                  color: AppColors.textPrimary,
                                  fontSize: 14, fontWeight: FontWeight.w600)),
                          SizedBox(height: 2),
                          Text('登录后查看作业、批改与订正',
                              style: TextStyle(
                                  color: AppColors.textMuted, fontSize: 12)),
                        ],
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: _openLogin,
                      icon: const Icon(Icons.login, size: 16),
                      label: const Text('去登录'),
                    ),
                  ])
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Container(
                        width: 38, height: 38,
                        decoration: BoxDecoration(
                          color: AppColors.green.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: const Icon(Icons.verified_user_outlined,
                            size: 20, color: AppColors.green),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                _semecUser!.realName.isNotEmpty
                                    ? _semecUser!.realName
                                    : _semecUser!.username,
                                style: const TextStyle(
                                    color: AppColors.textPrimary,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(height: 2),
                            Text(
                                '${_roleLabel(_semecUser!.role)} · '
                                '${ServerConfig.instance.semecBaseUrl}',
                                maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: AppColors.textMuted,
                                    fontSize: 11,
                                    fontFamily: 'monospace')),
                          ],
                        ),
                      ),
                    ]),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _semecLogout,
                        icon: const Icon(Icons.logout,
                            size: 18, color: AppColors.red),
                        label: const Text('退出登录',
                            style: TextStyle(color: AppColors.red)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppColors.red),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ]),
          ),

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

  String _roleLabel(String role) => switch (role) {
        'teacher' => '教师',
        'student' => '学生',
        _ => role,
      };

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
