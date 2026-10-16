// lib/utils/app_navigator.dart
// 全局 Navigator key：供无 BuildContext 的网络层弹出登录过期提示
import 'package:flutter/material.dart';
import '../api/semec_teaching_api.dart';
import '../screens/login_screen.dart';

final appNavigatorKey = GlobalKey<NavigatorState>();

/// 登录拦截：已登录直接 true；未登录推送专用登录页，登录成功返回 true、取消返回 false。
///
///   final ok = await ensureLoggedIn(context, reason: '登录后查看作业');
///   if (!ok || !context.mounted) return;
///   Navigator.push(...目标页...);
Future<bool> ensureLoggedIn(BuildContext context, {String? reason}) async {
  // 冷启动瞬间 token 尚在异步读取：等加载完成再判登录态，避免误弹登录页
  await SemecTeachingApi.instance.tokensReady.future;
  if (SemecTeachingApi.instance.isLoggedIn) return true;
  final ok = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => LoginScreen(reason: reason),
    ),
  );
  return ok ?? false;
}
