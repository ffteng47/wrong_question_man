// lib/utils/platform_open_file.dart
// 调起系统查看器打开本地文件（作业 PDF）。
// 原生实现见 MainActivity.kt 的 wqm/open_file 通道（FileProvider + ACTION_VIEW）。
import 'package:flutter/services.dart';

class PlatformOpenFile {
  static const _channel = MethodChannel('wqm/open_file');

  /// 成功返回 null；无可用应用/失败返回可直接展示的中文文案。
  static Future<String?> open(String path, {String? mimeType}) async {
    try {
      await _channel.invokeMethod('open', {
        'path': path,
        'mime': mimeType,
      });
      return null;
    } on PlatformException catch (e) {
      return e.message ?? '无法打开文件';
    } on MissingPluginException {
      return '当前设备不支持打开文件';
    }
  }
}
