// lib/screens/paper_result_screen.dart
// 判题任务详情：状态轮询（30s，仅非终态）+ 页图 question_region 百分比框叠加 + 逐题结果
// 坐标口径：question_region 0~1000 归一，left=x1/10%（详设 v2.2，无需页宽换算）
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../api/semec_teaching_api.dart';
import '../models/paper_models.dart';
import '../utils/theme.dart';

class PaperResultScreen extends StatefulWidget {
  final int uploadId;
  final String? uploadNo;
  const PaperResultScreen({super.key, required this.uploadId, this.uploadNo});

  @override
  State<PaperResultScreen> createState() => _PaperResultScreenState();
}

class _PaperResultScreenState extends State<PaperResultScreen> {
  Timer? _pollTimer;
  PaperUploadDetail? _detail;
  final Map<int, Uint8List> _pageImages = {};
  final Map<int, bool> _pageLoading = {};
  bool _loading = true;
  String? _error;

  static const _terminalColor = {
    '完成': AppColors.green,
    '部分完成': AppColors.amber,
    '等待人工确认': AppColors.amber,
    '处理失败': AppColors.red,
  };

  @override
  void initState() {
    super.initState();
    _load(initial: true);
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool initial = false}) async {
    try {
      final detail = await SemecTeachingApi.instance
          .getPaperUpload(widget.uploadId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
        _error = null;
      });
      for (final p in detail.pages) {
        _loadPageImage(p.id);
      }
      // 非终态 → 30s 轮询；终态 → 停止
      _pollTimer?.cancel();
      if (!detail.isTerminal) {
        _pollTimer = Timer.periodic(
            const Duration(seconds: 30), (_) => _load());
      }
    } catch (e) {
      if (!mounted) return;
      if (initial) {
        setState(() { _loading = false; _error = e.toString(); });
      } else {
        setState(() => _error = e.toString());
      }
    }
  }

  Future<void> _loadPageImage(int pageId) async {
    if (_pageImages.containsKey(pageId) || (_pageLoading[pageId] ?? false)) {
      return;
    }
    _pageLoading[pageId] = true;
    try {
      final bytes =
          await SemecTeachingApi.instance.fetchPaperPageImage(pageId);
      if (mounted) setState(() => _pageImages[pageId] = bytes);
    } catch (_) {
      // 图片加载失败不阻塞结果展示
    } finally {
      _pageLoading[pageId] = false;
    }
  }

  Color _gradeColor(String grade) => switch (grade) {
    'correct' => AppColors.green,
    'wrong' => AppColors.red,
    'partial' => AppColors.amber,
    _ => AppColors.textSecondary,
  };

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      backgroundColor: AppColors.bg0,
      appBar: AppBar(
        title: Text(detail?.uploadNo ?? widget.uploadNo ?? '判题任务'),
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(),
        color: AppColors.amber,
        backgroundColor: AppColors.bg2,
        child: _loading
            ? const Center(child: CircularProgressIndicator(
                color: AppColors.amber, strokeWidth: 2))
            : detail == null
                ? ListView(children: [
                    const SizedBox(height: 100),
                    Center(child: Text(_error ?? '任务不存在',
                        style: const TextStyle(color: AppColors.red))),
                  ])
                : _buildDetail(detail),
      ),
    );
  }

  Widget _buildDetail(PaperUploadDetail detail) {
    final processing = !detail.isTerminal;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
      children: [
        // ── 状态条 ──
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.bg1,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: _terminalColor[detail.status] ?? AppColors.bg3),
          ),
          child: Row(
            children: [
              if (processing)
                const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.amber))
              else
                Icon(
                  detail.status == '完成'
                      ? Icons.check_circle_outline
                      : detail.status == '处理失败'
                          ? Icons.error_outline
                          : Icons.hourglass_bottom,
                  size: 18,
                  color: _terminalColor[detail.status] ??
                      AppColors.textSecondary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  processing
                      ? '${detail.status}…（每 30 秒自动刷新）'
                      : detail.status,
                  style: TextStyle(
                      color: _terminalColor[detail.status] ??
                          AppColors.textSecondary,
                      fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
              Text('${detail.totalPages} 页',
                  style: const TextStyle(
                      color: AppColors.textMuted, fontSize: 12)),
            ],
          ),
        ),
        const SizedBox(height: 8),
        if (_error != null && _detail != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(_error!,
                style: const TextStyle(color: AppColors.amber, fontSize: 12)),
          ),

        // ── 逐页：图片 + 题目定位框 ──
        for (final page in detail.pages) ...[
          const SizedBox(height: 12),
          Text('第 ${page.pageNo} 页', style: AppText.label),
          const SizedBox(height: 6),
          _buildPageCard(page, detail.results),
        ],

        // ── 逐题结果 ──
        if (detail.results.isNotEmpty) ...[
          const SizedBox(height: 20),
          const Text('题目结果', style: AppText.label),
          const SizedBox(height: 6),
          ...detail.results.map((r) => _buildResultRow(r)),
        ] else if (!processing) ...[
          const SizedBox(height: 20),
          const Text('暂无判题结果',
              style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
        ],
      ],
    );
  }

  Widget _buildPageCard(PaperPage page, List<PaperResult> results) {
    final pageResults =
        results.where((r) => r.pageId == page.id && r.questionRegion != null)
            .toList();
    final bytes = _pageImages[page.id];
    final aspect = (page.width != null && page.height != null &&
            page.height! > 0)
        ? page.width! / page.height!
        : null;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.bg1,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.bg3),
      ),
      clipBehavior: Clip.antiAlias,
      child: bytes == null
          ? SizedBox(
              height: 160,
              child: Center(
                child: (_pageLoading[page.id] ?? false)
                    ? const CircularProgressIndicator(
                        color: AppColors.amber, strokeWidth: 2)
                    : const Icon(Icons.broken_image_outlined,
                        color: AppColors.textMuted),
              ),
            )
          : LayoutBuilder(builder: (ctx, cons) {
              final image = Image.memory(bytes,
                  fit: BoxFit.contain, gaplessPlayback: true);
              // 有 width/height 元数据 → AspectRatio 定比例，叠加框直接按百分比铺
              // 无元数据 → contain 渲染有黑边，按内缩矩形换算
              return aspect != null
                  ? AspectRatio(
                      aspectRatio: aspect,
                      child: Stack(fit: StackFit.expand, children: [
                        image,
                        ..._overlaysAt(cons.biggest, pageResults),
                      ]),
                    )
                  : Stack(fit: StackFit.expand, children: [
                      image,
                      ..._overlaysContain(cons.biggest, page, pageResults),
                    ]);
            }),
    );
  }

  List<Widget> _overlaysContain(
      Size size, PaperPage page, List<PaperResult> results) {
    // BoxFit.contain 下图片实际区域可能有黑边；有宽高元数据则换算内缩矩形
    if (page.width == null || page.height == null ||
        page.width! <= 0 || page.height! <= 0) {
      return _overlaysAt(size, results);
    }
    final imgRatio = page.width! / page.height!;
    final boxRatio = size.width / size.height;
    double w, h;
    if (imgRatio > boxRatio) { w = size.width; h = size.width / imgRatio; }
    else { h = size.height; w = size.height * imgRatio; }
    final dx = (size.width - w) / 2, dy = (size.height - h) / 2;
    return results.map((r) {
      final f = r.questionRegion!;
      return Positioned(
        left: dx + f[0] / 1000 * w,
        top: dy + f[1] / 1000 * h,
        width: (f[2] - f[0]) / 1000 * w,
        height: (f[3] - f[1]) / 1000 * h,
        child: _regionBox(r),
      );
    }).toList();
  }

  List<Widget> _overlaysAt(Size size, List<PaperResult> results) {
    return results.map((r) {
      final f = r.questionRegion!;
      return Positioned(
        left: f[0] / 1000 * size.width,
        top: f[1] / 1000 * size.height,
        width: (f[2] - f[0]) / 1000 * size.width,
        height: (f[3] - f[1]) / 1000 * size.height,
        child: _regionBox(r),
      );
    }).toList();
  }

  Widget _regionBox(PaperResult r) {
    final color = _gradeColor(r.grade);
    return GestureDetector(
      onTap: () => _showResultSheet(r),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: color, width: 2),
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(3),
        ),
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Text(
            r.score != null
                ? '${r.score!}/${r.maxScore ?? '-'}'
                : r.gradeLabel,
            style: TextStyle(
                color: color, fontSize: 10, fontWeight: FontWeight.w700),
          ),
        ),
      ),
    );
  }

  Widget _buildResultRow(PaperResult r) {
    final color = _gradeColor(r.grade);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.bg1,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _showResultSheet(r),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withOpacity(0.4)),
            ),
            child: Row(
              children: [
                Container(
                  width: 4, height: 36,
                  decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(2)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    (r.questionText ?? r.questionContent ?? r.recognizedText ?? '')
                        .replaceAll('\n', ' ')
                        .trim(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 13),
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(r.gradeLabel,
                        style: TextStyle(
                            color: color, fontSize: 12,
                            fontWeight: FontWeight.w600)),
                    if (r.score != null) ...[
                      const SizedBox(height: 2),
                      Text('${r.score!}'
                          '${r.maxScore != null ? ' / ${r.maxScore!}' : ''}',
                          style: const TextStyle(
                              color: AppColors.textMuted, fontSize: 11)),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showResultSheet(PaperResult r) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.bg1,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('题目详情', style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: _gradeColor(r.grade).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(r.gradeLabel,
                        style: TextStyle(
                            color: _gradeColor(r.grade), fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (r.questionText != null)
                _sheetBlock('卷面题干', r.questionText!),
              if (r.questionContent != null)
                _sheetBlock('题库题面', r.questionContent!),
              if (r.recognizedText != null && r.recognizedText!.isNotEmpty)
                _sheetBlock('识别到的作答', r.recognizedText!),
              if (r.questionAnswer != null)
                _sheetBlock('参考答案', r.questionAnswer!),
              if (r.feedback != null)
                _sheetBlock('讲评', r.feedback!),
              if (r.reason != null)
                _sheetBlock('判题原因', r.reason!),
              if (r.score != null)
                _sheetBlock('得分',
                    '${r.score!}${r.maxScore != null ? ' / ${r.maxScore!}' : ''}'),
              if ((r.questionText == null) && (r.questionContent == null) &&
                  (r.recognizedText == null))
                const Text('该题暂无可展示内容（可能仍在识别中）',
                    style: TextStyle(
                        color: AppColors.textMuted, fontSize: 13)),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sheetBlock(String label, String content) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppText.label),
        const SizedBox(height: 4),
        Text(content, style: const TextStyle(
            color: AppColors.textSecondary, fontSize: 13, height: 1.5)),
      ],
    ),
  );
}
