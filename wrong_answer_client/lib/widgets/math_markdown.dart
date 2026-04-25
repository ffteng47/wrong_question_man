// lib/widgets/math_markdown.dart
//
// flutter_markdown + flutter_math_fork 渲染 Markdown 含 $LaTeX$
// 同时处理 ![caption](assets/...) 图片路径映射到服务端静态 URL
//
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;
import '../utils/theme.dart';

class MathMarkdown extends StatelessWidget {
  final String data;
  final double fontSize;
  final bool selectable;

  const MathMarkdown({
    super.key,
    required this.data,
    this.fontSize = 15,
    this.selectable = false,
  });

  @override
  Widget build(BuildContext context) {
    // 预处理：把 $...$ 替换为 MathInline 自定义语法可识别的形式
    // flutter_markdown 本身不支持 LaTeX，我们用 InlineSpan 自定义处理
    return _MathMarkdownBody(
      data: data,
      fontSize: fontSize,
      selectable: selectable,
    );
  }
}

class _MathMarkdownBody extends StatelessWidget {
  final String data;
  final double fontSize;
  final bool selectable;

  const _MathMarkdownBody({
    required this.data,
    required this.fontSize,
    required this.selectable,
  });

  @override
  Widget build(BuildContext context) {
    // 把 Markdown 文本按 $...$ 分段，混合渲染文本和公式
    final segments = _parseSegments(data);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: segments.map((seg) {
        if (seg.isFormula) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: _buildFormula(seg.content, block: seg.isBlock),
          );
        }
        // 普通 Markdown 段落
        if (seg.content.trim().isEmpty) return const SizedBox(height: 8);
        return MarkdownBody(
          data: seg.content,
          selectable: selectable,
          imageBuilder: (uri, title, alt) => _buildRemoteImage(uri),
          styleSheet: _buildStyleSheet(context, fontSize),
          extensionSet: md.ExtensionSet.gitHubWeb,
        );
      }).toList(),
    );
  }

  Widget _buildFormula(String tex, {bool block = false}) {
    final widget = Math.tex(
      tex,
      textStyle: TextStyle(
        fontSize: block ? fontSize + 2 : fontSize,
        color: AppColors.textPrimary,
      ),
      onErrorFallback: (e) => SelectableText(
        tex,
        style: TextStyle(
          fontFamily: 'monospace',
          color: AppColors.purple,
          fontSize: fontSize - 1,
        ),
      ),
    );
    if (block) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: widget,
        ),
      );
    }
    return widget;
  }

  Widget _buildRemoteImage(Uri uri) {
    // assets/xxx/fig_1.png → http://<server>/static/assets/xxx/fig_1.png
    final path = uri.toString();
    final url = path.startsWith('http')
        ? path
        : '${AppConst.baseUrl}/static/$path';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          url,
          errorBuilder: (_, __, ___) => Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.bg2,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.bg3),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.broken_image_outlined,
                    size: 16, color: AppColors.textMuted),
                const SizedBox(width: 6),
                Text(url.split('/').last,
                    style: AppText.mono),
              ],
            ),
          ),
        ),
      ),
    );
  }

  MarkdownStyleSheet _buildStyleSheet(BuildContext ctx, double fs) {
    return MarkdownStyleSheet(
      p: TextStyle(color: AppColors.textPrimary, fontSize: fs, height: 1.65),
      h1: TextStyle(color: AppColors.textPrimary, fontSize: fs + 4,
          fontWeight: FontWeight.w700),
      h2: TextStyle(color: AppColors.textPrimary, fontSize: fs + 2,
          fontWeight: FontWeight.w600),
      h3: TextStyle(color: AppColors.textSecondary, fontSize: fs + 1,
          fontWeight: FontWeight.w600),
      code: TextStyle(
        fontFamily: 'monospace',
        color: AppColors.purple,
        backgroundColor: AppColors.bg2,
        fontSize: fs - 1,
      ),
      codeblockDecoration: BoxDecoration(
        color: AppColors.bg2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.bg3),
      ),
      blockquoteDecoration: const BoxDecoration(
        border: Border(left: BorderSide(color: AppColors.amber, width: 3)),
        color: Colors.transparent,
      ),
      blockquote: TextStyle(
          color: AppColors.textSecondary, fontSize: fs, fontStyle: FontStyle.italic),
      strong: TextStyle(
          color: AppColors.textPrimary, fontWeight: FontWeight.w700, fontSize: fs),
      em: TextStyle(
          color: AppColors.amber, fontStyle: FontStyle.italic, fontSize: fs),
      listBullet: TextStyle(color: AppColors.amber, fontSize: fs),
      tableHead: TextStyle(
          color: AppColors.textPrimary, fontWeight: FontWeight.w600, fontSize: fs),
      tableBody: TextStyle(color: AppColors.textSecondary, fontSize: fs),
      tableBorder: TableBorder.all(color: AppColors.bg3),
      tableHeadAlign: TextAlign.left,
    );
  }
}

// ── 文本段解析（分离公式和普通文本）─────────────────────────────────────────

class _Segment {
  final String content;
  final bool isFormula;
  final bool isBlock;   // $$ ... $$ 块级公式

  _Segment(this.content, {this.isFormula = false, this.isBlock = false});
}

List<_Segment> _parseSegments(String text) {
  final segments = <_Segment>[];
  // 先处理 $$...$$（块级），再处理 $...$（行内）
  final blockRe = RegExp(r'\$\$([\s\S]+?)\$\$');
  final inlineRe = RegExp(r'\$([^\$\n]+?)\$');

  var remaining = text;
  while (remaining.isNotEmpty) {
    // 查找最近的公式标记
    final blockMatch = blockRe.firstMatch(remaining);
    final inlineMatch = inlineRe.firstMatch(remaining);

    Match? first;
    bool isBlock = false;

    if (blockMatch != null && inlineMatch != null) {
      if (blockMatch.start <= inlineMatch.start) {
        first = blockMatch; isBlock = true;
      } else {
        first = inlineMatch;
      }
    } else if (blockMatch != null) {
      first = blockMatch; isBlock = true;
    } else if (inlineMatch != null) {
      first = inlineMatch;
    }

    if (first == null) {
      segments.add(_Segment(remaining));
      break;
    }

    if (first.start > 0) {
      segments.add(_Segment(remaining.substring(0, first.start)));
    }
    segments.add(_Segment(
      first.group(1)!.trim(),
      isFormula: true,
      isBlock: isBlock,
    ));
    remaining = remaining.substring(first.end);
  }

  return segments;
}
