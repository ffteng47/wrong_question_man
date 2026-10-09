// lib/screens/paper_result_screen.dart
// 判题任务详情：状态轮询（30s，仅非终态）+ 页图 question_region 百分比框叠加 + 逐题结果
// 坐标口径：question_region 0~1000 归一，left=x1/10%（详设 v2.2，无需页宽换算）
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../api/semec_teaching_api.dart';
import '../models/paper_models.dart';
import '../utils/db_helper.dart';
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
  // 图片按 '${pageId}_$type' 缓存（批改标注 / 学生原图各自一份）
  final Map<String, Uint8List> _pageImages = {};
  final Map<String, bool> _pageLoading = {};
  String _imageType = 'normalized';
  bool _loading = true;
  String? _error;

  static const _terminalColor = {
    '完成': AppColors.green,
    '部分完成': AppColors.amber,
    '等待人工确认': AppColors.amber,
    '处理失败': AppColors.red,
  };

  /// 进度映射，与后端 paperPipelineProcessor.PROGRESS_BY_STATUS 一致
  static const _progressByStatus = {
    '已上传': 0.05,
    '文档处理中': 0.15,
    '页面解析完成': 0.40,
    '题目定位中': 0.50,
    '判题中': 0.80,
    '等待人工确认': 0.90,
    '部分完成': 0.95,
    '完成': 1.0,
    '处理失败': 0.0,
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
      // 终态 → 清本地待处理；非终态 → 续保活
      if (detail.isTerminal) {
        await DbHelper.instance.deletePendingUpload(detail.id);
      } else {
        await DbHelper.instance.upsertPendingUpload(
          uploadId: detail.id,
          uploadNo: detail.uploadNo,
          status: detail.status,
        );
      }
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

  Future<void> _loadPageImage(int pageId, {String? type}) async {
    final t = type ?? _imageType;
    final key = '${pageId}_$t';
    if (_pageImages.containsKey(key) || (_pageLoading[key] ?? false)) {
      return;
    }
    _pageLoading[key] = true;
    try {
      final bytes = await SemecTeachingApi.instance
          .fetchPaperPageImage(pageId, type: t);
      if (mounted) setState(() => _pageImages[key] = bytes);
    } catch (_) {
      // 图片加载失败不阻塞结果展示
    } finally {
      _pageLoading[key] = false;
    }
  }

  void _switchImageType(String t) {
    if (_imageType == t) return;
    setState(() => _imageType = t);
    for (final p in _detail?.pages ?? const <PaperPage>[]) {
      _loadPageImage(p.id, type: t);
    }
  }

  /// 判题统计（以行级结果为准，未判行计为老师正在批改）
  Map<String, int> _judgingStats(List<PaperResult> results) {
    final c = {'total': results.length, 'correct': 0, 'wrong': 0,
               'partial': 0, 'pending': 0};
    for (final r in results) {
      switch (r.grade) {
        case 'correct': c['correct'] = c['correct']! + 1;
        case 'wrong': c['wrong'] = c['wrong']! + 1;
        case 'partial': c['partial'] = c['partial']! + 1;
        default: c['pending'] = c['pending']! + 1;
      }
    }
    return c;
  }

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

        // ── 进度条（对齐后端 PROGRESS_BY_STATUS）──
        const SizedBox(height: 12),
        Builder(builder: (_) {
          final fraction = _progressByStatus[detail.status] ?? 0;
          return Row(children: [
            Expanded(child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 8,
                backgroundColor: AppColors.bg2,
                color: _terminalColor[detail.status] ?? AppColors.amber,
              ),
            )),
            const SizedBox(width: 10),
            Text('${(fraction * 100).round()}%',
                style: const TextStyle(
                    color: AppColors.textMuted, fontSize: 12)),
          ]);
        }),

        // ── 判题统计（共/对/错/部分对/老师正在批改）──
        const SizedBox(height: 12),
        Builder(builder: (_) {
          final s = _judgingStats(detail.results);
          return Wrap(spacing: 6, runSpacing: 6, children: [
            _statChip('共 ${s['total']} 题', AppColors.textSecondary),
            _statChip('对 ${s['correct']}', AppColors.green),
            _statChip('错 ${s['wrong']}', AppColors.red),
            _statChip('部分对 ${s['partial']}', AppColors.amber),
            _statChip('老师正在批改 ${s['pending']}', AppColors.textMuted),
          ]);
        }),

        // ── 图片切换：批改标注 / 学生原图（原图不画框）──
        const SizedBox(height: 12),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'normalized', label: Text('批改标注')),
            ButtonSegment(value: 'original', label: Text('学生原图')),
          ],
          selected: {_imageType},
          showSelectedIcon: false,
          onSelectionChanged: (v) => _switchImageType(v.first),
          style: ButtonStyle(
            visualDensity: VisualDensity.compact,
            foregroundColor: WidgetStateProperty.resolveWith((states) =>
                states.contains(WidgetState.selected)
                    ? AppColors.bg0 : AppColors.textSecondary),
          ),
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
    final bytes = _pageImages['${page.id}_$_imageType'];
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
                child: (_pageLoading['${page.id}_$_imageType'] ?? false)
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
    // 坐标基于批改标注图；学生原图 EXIF/尺寸可能不同，不画框
    if (_imageType != 'normalized') return const [];
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
    if (_imageType != 'normalized') return const [];
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
    final color = gradeColorOf(r.grade);
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
    final color = gradeColorOf(r.grade);
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

  Widget _statChip(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withOpacity(0.12),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(text,
        style: TextStyle(color: color, fontSize: 11,
            fontWeight: FontWeight.w600)),
  );

  void _showResultSheet(PaperResult r) {
    // 上一处/下一处口径：同页结果顺序
    final samePage = (_detail?.results ?? const <PaperResult>[])
        .where((x) => x.pageId == r.pageId).toList();
    final index = samePage.indexOf(r);
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.bg1,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _ResultSheet(
        results: samePage,
        initialIndex: index < 0 ? 0 : index,
      ),
    );
  }
}

Color gradeColorOf(String grade) => switch (grade) {
  'correct' => AppColors.green,
  'wrong' => AppColors.red,
  'partial' => AppColors.amber,
  _ => AppColors.textSecondary,
};

/// 题目详情 sheet（同页结果可上一处/下一处切换）
class _ResultSheet extends StatefulWidget {
  final List<PaperResult> results;
  final int initialIndex;
  const _ResultSheet({required this.results, required this.initialIndex});

  @override
  State<_ResultSheet> createState() => _ResultSheetState();
}

class _ResultSheetState extends State<_ResultSheet> {
  final _picker = ImagePicker();
  late int _index = widget.initialIndex;

  // ── 订正区状态 ──
  List<PaperCorrection> _corrections = const [];
  bool _corrLoading = false;
  bool _formOpen = false;
  File? _photo;
  int? _errorTag;
  bool _submitting = false;

  PaperResult get _r => widget.results[_index];

  bool get _correctable =>
      _r.grade == 'wrong' || _r.grade == 'partial';

  @override
  void initState() {
    super.initState();
    if (_correctable) _loadCorrections();
  }

  void _go(int offset) {
    final next = _index + offset;
    if (next >= 0 && next < widget.results.length) {
      setState(() {
        _index = next;
        _formOpen = false;
        _photo = null;
        _errorTag = null;
        _corrections = const [];
      });
      if (_correctable) _loadCorrections();
    }
  }

  Future<void> _loadCorrections() async {
    setState(() => _corrLoading = true);
    try {
      final list = await SemecTeachingApi.instance
          .getPaperCorrections(_r.resultId);
      if (mounted) setState(() => _corrections = list);
    } catch (_) {
      if (mounted) setState(() => _corrections = const []);
    } finally {
      if (mounted) setState(() => _corrLoading = false);
    }
  }

  Future<void> _pickPhoto(ImageSource source) async {
    final x = await _picker.pickImage(
        source: source, imageQuality: 95, maxWidth: 4000);
    if (x != null && mounted) setState(() => _photo = File(x.path));
  }

  /// recognized_text 为 JSON 数组字符串（对齐 Vue parseRecognizedText）
  String _parseRecognized(String? raw) {
    if (raw == null || raw.isEmpty) return '—';
    try {
      final p = jsonDecode(raw);
      if (p is List) {
        return p.where((t) => t != null && '$t'.trim().isNotEmpty)
            .join('，');
      }
      return '$p';
    } catch (_) {
      return raw;
    }
  }

  Future<void> _submitCorrection() async {
    final photo = _photo;
    if (photo == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先拍照或选择订正照片')));
      return;
    }
    setState(() => _submitting = true);
    try {
      final res = await SemecTeachingApi.instance
          .submitPhotoPaperCorrection(
            _r.resultId, photo,
            errorTagIds: _errorTag == null ? const [] : [_errorTag!],
          );
      if (!mounted) return;
      final text = res.gradingResult == 'correct'
          ? '订正正确！已计入复习计划'
          : res.status == 'needs_teacher'
              ? '已提交，等待老师复核'
              : '订正仍未正确：${res.feedback ?? '请查看后再试'}';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(text)));
      setState(() { _formOpen = false; _photo = null; _errorTag = null; });
      await _loadCorrections();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('订正提交失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Widget _block(String label, String content) => Padding(
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

  Widget _corrTag(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: AppColors.amber.withOpacity(0.15),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(text, style: const TextStyle(
        color: AppColors.amber, fontSize: 11, fontWeight: FontWeight.w600)),
  );

  Widget _buildCorrectionSection() {
    final current = _corrections.isNotEmpty ? _corrections.first : null;
    final history = _corrections.length > 1
        ? _corrections.sublist(1) : const <PaperCorrection>[];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.bg3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('我的订正', style: AppText.label),
          const Spacer(),
          if (_corrections.length < 3)
            OutlinedButton(
              onPressed: _submitting
                  ? null : () => setState(() => _formOpen = !_formOpen),
              child: Text(_corrections.isEmpty ? '订正' : '再做一遍'),
            )
          else
            const Text('已达 3 轮上限',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
        ]),
        if (_corrLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('加载中…',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
          )
        else if (current != null) ...[
          const SizedBox(height: 8),
          Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6,
              children: [
            _corrTag(current.label),
            Text('第 ${current.roundNo} 轮 · '
                '${current.channel == 'photo' ? '拍照' : '在线'}',
                style: const TextStyle(
                    color: AppColors.textMuted, fontSize: 12)),
          ]),
          const SizedBox(height: 6),
          Text('我的订正：${_parseRecognized(current.recognizedText)}',
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 12)),
          if ((current.gradingFeedback ?? '').isNotEmpty ||
              (current.gradingReason ?? '').isNotEmpty) ...[
            const SizedBox(height: 4),
            Text([
              if ((current.gradingFeedback ?? '').isNotEmpty)
                current.gradingFeedback,
              if ((current.gradingReason ?? '').isNotEmpty)
                current.gradingReason,
            ].whereType<String>().join('\n'),
                style: const TextStyle(
                    color: AppColors.textMuted, fontSize: 12)),
          ],
          if (history.isNotEmpty)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              dense: true,
              title: Text('历史订正（${history.length}）',
                  style: const TextStyle(fontSize: 12)),
              children: history.map((h) => Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    '第 ${h.roundNo} 轮 · ${h.label} · '
                    '${_parseRecognized(h.recognizedText)}',
                    style: const TextStyle(
                        color: AppColors.textMuted, fontSize: 12)),
                ),
              )).toList(),
            ),
        ],
        if (_formOpen) ...[
          const Divider(height: 20),
          const Text('这道题错在哪里？（可选）',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final t in kPaperErrorTags)
              ChoiceChip(
                label: Text(t.name),
                selected: _errorTag == t.id,
                visualDensity: VisualDensity.compact,
                onSelected: (v) =>
                    setState(() => _errorTag = v ? t.id : null),
              ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            OutlinedButton.icon(
              onPressed: _submitting
                  ? null : () => _pickPhoto(ImageSource.camera),
              icon: const Icon(Icons.camera_alt_outlined, size: 16),
              label: const Text('拍照'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _submitting
                  ? null : () => _pickPhoto(ImageSource.gallery),
              icon: const Icon(Icons.photo_library_outlined, size: 16),
              label: const Text('相册'),
            ),
          ]),
          if (_photo != null) ...[
            const SizedBox(height: 8),
            Text('已选择：${_photo!.path.split(Platform.pathSeparator).last}',
                style: const TextStyle(
                    color: AppColors.textMuted, fontSize: 12)),
          ],
          const SizedBox(height: 10),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(
              onPressed: _submitting
                  ? null : () => setState(() => _formOpen = false),
              child: const Text('取消'),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: _submitting ? null : _submitCorrection,
              child: _submitting
                  ? const SizedBox(width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('提交订正'),
            ),
          ]),
        ],
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    final color = gradeColorOf(r.grade);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('题目详情', style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 16, fontWeight: FontWeight.w600)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(r.gradeLabel,
                      style: TextStyle(color: color, fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (r.questionText != null)
              _block('卷面题干', r.questionText!),
            if (r.questionContent != null)
              _block('题库题面', r.questionContent!),
            if (r.recognizedText != null && r.recognizedText!.isNotEmpty)
              _block('识别到的作答', r.recognizedText!),
            if (r.questionAnswer != null)
              _block('参考答案', r.questionAnswer!),
            if (r.feedback != null)
              _block('讲评', r.feedback!),
            if (r.reason != null)
              _block('判题原因', r.reason!),
            if (r.score != null)
              _block('得分',
                  '${r.score!}${r.maxScore != null ? ' / ${r.maxScore!}' : ''}'),
            if ((r.questionText == null) && (r.questionContent == null) &&
                (r.recognizedText == null))
              const Text('该题暂无可展示内容（可能仍在识别中）',
                  style: TextStyle(
                      color: AppColors.textMuted, fontSize: 13)),
            if (_correctable) _buildCorrectionSection(),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              Text('第 ${_index + 1} / ${widget.results.length} 处',
                  style: const TextStyle(
                      color: AppColors.textMuted, fontSize: 12)),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _index <= 0 ? null : () => _go(-1),
                child: const Text('上一处'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _index >= widget.results.length - 1
                    ? null : () => _go(1),
                child: const Text('下一处'),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
