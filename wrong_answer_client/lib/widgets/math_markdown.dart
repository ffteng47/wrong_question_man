// lib/widgets/math_markdown.dart
//
// flutter_markdown + flutter_math_fork 渲染 Markdown 含 $LaTeX$
// 同时处理 ![caption](assets/...) 图片路径映射到服务端静态 URL
//
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;
import '../utils/server_config.dart';
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
    // $$块公式$$ 独立居中；块之间的文本走 Text.rich 流式渲染（行内公式内嵌），
    // 不再把每个 $公式$ 切成独立段——旧实现节点间强制断行，连续行文被拆成
    // 一段一段（与网页端 joinNodes 之前的 \n\n bug 同构）
    final blocks = _parseBlocks(data);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final b in blocks)
          if (b.isFormula)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Center(child: _buildFormula(b.content, block: true)),
            )
          else
            _renderTextBlock(context, b.content),
      ],
    );
  }

  /// 块级 Markdown 特征（表格/图片/标题/列表/引用/代码块）：含这些才走
  /// MarkdownBody 重路径；普通行文（含行内公式、<br>）走 Text.rich 轻路径
  static final _heavyMarkdown = RegExp(
    r'(^\s{0,3}#{1,6}\s)|(^\s*\|.*\|\s*$)|(!\[)|'
    r'(^\s*(?:[-*+]|\d+[.)])\s+)|(```)|(^\s{0,3}>\s)|(^\s*[-*_]{3,}\s*$)',
    multiLine: true,
  );

  /// <br>（含 <br/> <br />）统一识别
  static final _brRe = RegExp(r'<br\s*/?>', caseSensitive: false);

  Widget _renderTextBlock(BuildContext context, String raw) {
    // 库里不少解析以 <br> 起头，trim 避免首行空行
    final text = raw.replaceAll(_brRe, '\n').trim();
    if (text.isEmpty) return const SizedBox.shrink();
    if (_heavyMarkdown.hasMatch(text)) {
      // 重 Markdown：退回 MarkdownBody 分段渲染（行内公式仍被拆出），
      // 单换行升级为段落，保证 <br> 在 Markdown 路径下也成立
      final segs = _parseSegments(text.replaceAll('\n', '\n\n'));
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final seg in segs)
            if (seg.isFormula)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: _buildFormula(seg.content, block: seg.isBlock),
              )
            else if (seg.content.trim().isNotEmpty)
              MarkdownBody(
                data: seg.content,
                selectable: selectable,
                imageBuilder: (uri, title, alt) => _buildRemoteImage(uri),
                styleSheet: _buildStyleSheet(context, fontSize),
                extensionSet: md.ExtensionSet.gitHubWeb,
              ),
        ],
      );
    }
    // 轻路径：单个 Text.rich，行内公式 WidgetSpan 内嵌，连续行文不强制断段
    return Text.rich(
      TextSpan(children: _inlineSpans(text)),
      softWrap: true,
    );
  }

  static final _inlineTokenRe =
      RegExp(r'\$([^$\n]+?)\$|\*\*([^*\n]+?)\*\*');

  List<InlineSpan> _inlineSpans(String text) {
    final base = TextStyle(
      color: AppColors.textPrimary,
      fontSize: fontSize,
      height: 1.65,
    );
    final spans = <InlineSpan>[];
    var pos = 0;
    for (final m in _inlineTokenRe.allMatches(text)) {
      if (m.start > pos) {
        spans.add(TextSpan(text: text.substring(pos, m.start), style: base));
      }
      final formula = m.group(1);
      if (formula != null) {
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Math.tex(
            formula.trim(),
            textStyle: base,
            onErrorFallback: (e) => Text(formula,
                style: base.copyWith(
                    fontFamily: 'monospace', color: AppColors.purple)),
          ),
        ));
      } else {
        spans.add(TextSpan(
            text: m.group(2),
            style: base.copyWith(fontWeight: FontWeight.w700)));
      }
      pos = m.end;
    }
    if (pos < text.length) {
      spans.add(TextSpan(text: text.substring(pos), style: base));
    }
    return spans;
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
        : '${ServerConfig.instance.apiBaseUrl}/static/$path';
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

/// 块级分段：$$...$$ 公式块 vs 普通文本块
class _Block {
  final String content;
  final bool isFormula;
  _Block(this.content, {this.isFormula = false});
}

List<_Block> _parseBlocks(String text) {
  final blocks = <_Block>[];
  final blockRe = RegExp(r'\$\$([\s\S]+?)\$\$');
  var pos = 0;
  for (final m in blockRe.allMatches(text)) {
    if (m.start > pos) blocks.add(_Block(text.substring(pos, m.start)));
    blocks.add(_Block(m.group(1)!.trim(), isFormula: true));
    pos = m.end;
  }
  if (pos < text.length) blocks.add(_Block(text.substring(pos)));
  return blocks;
}

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
