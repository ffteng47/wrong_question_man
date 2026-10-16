// lib/screens/login_screen.dart
//
// semecTeaching 学校账号登录页（独立全屏页）。
// 入口：未登录点「我的作业/作业任务/分配」时的登录拦截、设置页「去登录」、401 过期弹窗。
// 登录成功 Navigator.pop(true)，取消/返回 pop(false)。
// 服务器地址收在「服务器设置」折叠区，日常使用不用碰。
import 'package:flutter/material.dart';
import '../api/semec_teaching_api.dart';
import '../utils/server_config.dart';
import '../utils/theme.dart';

class LoginScreen extends StatefulWidget {
  /// 场景说明，如「登录后查看作业、批改结果与订正」
  final String? reason;

  const LoginScreen({super.key, this.reason});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _urlCtrl =
      TextEditingController(text: ServerConfig.instance.semecBaseUrl);
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _loggingIn = false;
  bool _obscure = true;
  bool _serverExpanded = false;
  String? _error;

  @override
  void dispose() {
    _urlCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() { _loggingIn = true; _error = null; });
    try {
      final url = _urlCtrl.text.trim();
      if (url.isNotEmpty && url != ServerConfig.instance.semecBaseUrl) {
        await ServerConfig.instance.setSemecBaseUrl(url);
      }
      final result = await SemecTeachingApi.instance
          .login(_userCtrl.text.trim(), _passCtrl.text);
      if (!mounted) return;
      if (result.success) {
        Navigator.of(context).pop(true);
      } else {
        setState(() {
          _loggingIn = false;
          _error = result.message ?? '登录失败，请检查账号或密码';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loggingIn = false;
        _error = _friendlyError(e);
      });
    }
  }

  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('Connection refused') || s.contains('connection error') ||
        s.contains('Failed host') || s.contains('SocketException')) {
      return '无法连接服务器，请检查地址或校内网络后重试';
    }
    if (s.contains('timed out') || s.contains('Timeout')) {
      return '连接超时，请确认与服务器在同一网络';
    }
    if (s.startsWith('Exception: ')) return s.substring(11);
    return s;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg0,
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── 顶栏：取消（离线功能仍可用，不强制登录）──
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed:
                        _loggingIn ? null : () => Navigator.of(context).pop(false),
                    child: const Text('以后再说'),
                  ),
                ),
                const SizedBox(height: 8),

                // ── 品牌区 ──
                Container(
                  width: 64, height: 64,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                        begin: Alignment.topLeft, end: Alignment.bottomRight,
                        colors: [AppColors.amber, Color(0xFFD2820A)]),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(color: AppColors.amber.withValues(alpha: 0.35),
                          blurRadius: 18, offset: const Offset(0, 6)),
                    ],
                  ),
                  child: const Icon(Icons.model_training,
                      size: 34, color: AppColors.bg0),
                ),
                const SizedBox(height: 20),
                const Text('欢迎使用错题本',
                    style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 24, fontWeight: FontWeight.w700,
                        letterSpacing: -0.4)),
                const SizedBox(height: 8),
                Text(widget.reason ?? '登录学校账号，查看作业、批改结果与在线订正',
                    style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 14, height: 1.5)),
                const SizedBox(height: 28),

                // ── 登录卡片 ──
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: AppColors.bg1,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.bg3),
                  ),
                  child: Form(
                    key: _formKey,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                      TextFormField(
                        controller: _userCtrl,
                        textInputAction: TextInputAction.next,
                        style: const TextStyle(
                            color: AppColors.textPrimary, fontSize: 15),
                        decoration: const InputDecoration(
                          labelText: '账号',
                          hintText: '学号 / 工号',
                          prefixIcon: Icon(Icons.person_outline, size: 20),
                        ),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? '请输入账号' : null,
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _passCtrl,
                        obscureText: _obscure,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _loggingIn ? null : _login(),
                        style: const TextStyle(
                            color: AppColors.textPrimary, fontSize: 15),
                        decoration: InputDecoration(
                          labelText: '密码',
                          hintText: '请输入密码',
                          prefixIcon: const Icon(Icons.lock_outline, size: 20),
                          suffixIcon: IconButton(
                            icon: Icon(_obscure
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                                size: 20),
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                          ),
                        ),
                        validator: (v) =>
                            (v == null || v.isEmpty) ? '请输入密码' : null,
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppColors.red.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: AppColors.red.withValues(alpha: 0.35)),
                          ),
                          child: Row(children: [
                            const Icon(Icons.error_outline,
                                size: 16, color: AppColors.red),
                            const SizedBox(width: 8),
                            Expanded(child: Text(_error!,
                                style: const TextStyle(
                                    color: AppColors.red, fontSize: 12.5,
                                    height: 1.45))),
                          ]),
                        ),
                      ],
                      const SizedBox(height: 20),
                      SizedBox(
                        height: 48,
                        child: ElevatedButton(
                          onPressed: _loggingIn ? null : _login,
                          style: ElevatedButton.styleFrom(
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                          ),
                          child: _loggingIn
                              ? const SizedBox(width: 20, height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2.2,
                                      color: AppColors.bg0))
                              : const Text('登 录',
                                  style: TextStyle(fontSize: 15)),
                        ),
                      ),
                    ]),
                  ),
                ),

                // ── 服务器设置（高级，默认折叠）──
                const SizedBox(height: 8),
                Theme(
                  data: Theme.of(context)
                      .copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    dense: true,
                    tilePadding:
                        const EdgeInsets.symmetric(horizontal: 8),
                    leading: const Icon(Icons.dns_outlined,
                        size: 18, color: AppColors.textMuted),
                    title: const Text('服务器设置',
                        style: TextStyle(
                            color: AppColors.textMuted, fontSize: 13)),
                    trailing: Icon(
                        _serverExpanded
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        color: AppColors.textMuted),
                    onExpansionChanged: (v) =>
                        setState(() => _serverExpanded = v),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                        child: TextField(
                          controller: _urlCtrl,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 13, fontFamily: 'monospace'),
                          decoration: const InputDecoration(
                            hintText: 'http://192.168.x.x:3000',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),
                // ── 底部说明 ──
                const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.verified_user_outlined,
                      size: 13, color: AppColors.textMuted),
                  SizedBox(width: 5),
                  const Text('账号由学校统一发放，仅用于校内作业服务',
                      style: TextStyle(
                          color: AppColors.textMuted, fontSize: 11.5)),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
