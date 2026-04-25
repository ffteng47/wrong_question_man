// lib/screens/settings_screen.dart
import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../utils/theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _urlCtrl = TextEditingController(text: AppConst.baseUrl);
  bool _testing = false;
  Map<String, dynamic>? _health;
  String? _error;

  @override
  void dispose() {
    _urlCtrl.dispose();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg0,
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // ── 服务器地址 ─────────────────────────────────────────────────────
          const Text('服务器地址', style: AppText.label),
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
