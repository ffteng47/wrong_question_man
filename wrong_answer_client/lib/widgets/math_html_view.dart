// lib/widgets/math_html_view.dart
//
// 富文本渲染（与网页端同一套管线）：本地 WebView + markdown-it + KaTeX。
// 题干/解析里的原始 HTML 表格、<br>、行内/块级公式由本地 H5（assets/web/viewer.html）
// 渲染，保真度与 PaperUploadDetail.vue 一致；资源全部本地打包，可离线。
// WebView 高度由 JS 按内容 scrollHeight 回传，适配外层滚动列表。
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../utils/server_config.dart';

class MathHtmlView extends StatefulWidget {
  final String data;
  final double fontSize;

  const MathHtmlView({
    super.key,
    required this.data,
    this.fontSize = 15,
  });

  @override
  State<MathHtmlView> createState() => _MathHtmlViewState();
}

class _MathHtmlViewState extends State<MathHtmlView> {
  late final WebViewController _controller;
  double? _height;
  bool _pageReady = false;

  /// assets/xxx → 服务端 /static/xxx（markdown 与裸 HTML 两种写法都覆盖）
  String _absoluteImages(String content) {
    final base = ServerConfig.instance.apiBaseUrl;
    return content
        .replaceAll('](assets/', ']($base/static/assets/')
        .replaceAll('="assets/', '="$base/static/assets/');
  }

  void _inject() {
    if (!_pageReady) return;
    final payload = jsonEncode({
      'content': _absoluteImages(widget.data),
      'fontSize': widget.fontSize,
    });
    _controller.runJavaScript('window.render($payload)');
  }

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setBackgroundColor(Colors.transparent)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('MathHtml', onMessageReceived: (msg) {
        final h = double.tryParse(msg.message);
        if (h != null && h > 0 && mounted && (h - (_height ?? 0)).abs() > 1) {
          setState(() => _height = h);
        }
      })
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          _pageReady = true;
          _inject();
        },
      ))
      ..loadFlutterAsset('assets/web/viewer.html');
  }

  @override
  void didUpdateWidget(MathHtmlView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data ||
        oldWidget.fontSize != widget.fontSize) {
      _inject();
    }
  }

  @override
  Widget build(BuildContext context) {
    // 高度未回传前占位，避免列表跳动太剧烈；WebView 与内容等高，
    // 自身不产生内部滚动，滚动交回外层 ListView
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      height: _height ?? 40,
      child: WebViewWidget(controller: _controller),
    );
  }
}
