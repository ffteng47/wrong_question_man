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
import '../widgets/math_html_view.dart';
import '../widgets/math_markdown.dart';

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
  // 当前打开详情的题目：图上对应框高亮（对齐网页 is-active）
  int? _selectedResultId;

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

        // ── 判题统计（设计稿：四等宽卡，手机 2×2；部分对/待批改收为副行）──
        const SizedBox(height: 12),
        Builder(builder: (_) {
          final s = _judgingStats(detail.results);
          final total = s['total']!;
          final rate = total == 0
              ? 0
              : (s['correct']! * 100 / total).round();
          return Column(children: [
            Row(children: [
              Expanded(child: _statCard('总题数', '$total',
                  AppColors.textPrimary)),
              const SizedBox(width: 12),
              Expanded(child: _statCard('正确', '${s['correct']}',
                  AppColors.green)),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _statCard('错误', '${s['wrong']}',
                  AppColors.red)),
              const SizedBox(width: 12),
              Expanded(child: _statCard('正确率', '$rate%',
                  AppColors.blue)),
            ]),
            if (s['partial']! > 0 || s['pending']! > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                      '部分对 ${s['partial']} · 待批改 ${s['pending']}',
                      style: const TextStyle(
                          color: AppColors.textMuted, fontSize: 11)),
                ),
              ),
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
        if (_imageType == 'normalized' && detail.results.any(
            (r) => r.questionRegion != null))
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('点击图中 ✓ / ✕ 标记查看该题详情，可左右滑动切换',
                style: TextStyle(
                    color: AppColors.textMuted, fontSize: 12)),
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
          // 必须在 AspectRatio 内部取 constraints：外层 ListView 高度无界，
          // 在外面拿到的 biggest.height 是 Infinity，百分比定位会算出无限框
          // （90000058 首份带坐标数据触发 BoxConstraints infinite height，框全不显示）
          : AspectRatio(
              aspectRatio: aspect ?? 3 / 4,
              // ponytail: 无页宽元数据时按竖版 3:4 兜底；正常批改标注图都带 width/height
              child: LayoutBuilder(builder: (ctx, cons) {
                return Stack(fit: StackFit.expand, children: [
                  Image.memory(bytes,
                      fit: BoxFit.contain, gaplessPlayback: true),
                  ..._overlaysAt(cons.biggest, pageResults),
                ]);
              }),
            ),
    );
  }

  List<Widget> _overlaysAt(Size size, List<PaperResult> results) {
    // 坐标基于批改标注图；学生原图 EXIF/尺寸可能不同，不画框
    if (_imageType != 'normalized') return const [];
    // 与 Web toBoxStyle 同口径：clamp 到 [0,1000]，脏数据不甩到画面外
    double clampNum(double v) => v.clamp(0, 1000).toDouble();
    return results.map((r) {
      final f = r.questionRegion!;
      final x1 = clampNum(f[0]), y1 = clampNum(f[1]);
      final x2 = clampNum(f[2]), y2 = clampNum(f[3]);
      final w = (x2 - x1).abs() / 1000 * size.width;
      final h = (y2 - y1).abs() / 1000 * size.height;
      return Positioned(
        left: x1 / 1000 * size.width,
        top: y1 / 1000 * size.height,
        width: w,
        height: h,
        child: _regionBox(r, w, h),
      );
    }).toList();
  }

  /// 题目区域框：常态细彩边 + 左上 ✓/✕ 圆形徽章（常显）；选中粗边浅底发光
  Widget _regionBox(PaperResult r, double boxW, double boxH) {
    final color = gradeColorOf(r.grade);
    final selected = _selectedResultId == r.resultId;
    // 极小框时徽章缩小，保证不出框
    final compact = boxW < 56 || boxH < 40;
    final badgeSize = compact ? 16.0 : 22.0;
    return GestureDetector(
      onTap: () => _showResultSheet(r),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          border: Border.all(
              color: color.withValues(alpha: selected ? 1 : 0.55),
              width: selected ? 2.5 : 1.5),
          color: selected ? color.withValues(alpha: 0.10) : null,
          borderRadius: BorderRadius.circular(3),
          boxShadow: selected
              ? [BoxShadow(color: color.withValues(alpha: 0.45),
                  blurRadius: 8, spreadRadius: 1)]
              : null,
        ),
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned(
            left: 2, top: 2,
            child: Container(
              width: badgeSize, height: badgeSize,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.92),
                shape: BoxShape.circle,
                border: Border.all(color: color, width: 1),
              ),
              alignment: Alignment.center,
              child: Icon(gradeMarkerIcon(r.grade),
                  size: compact ? 11 : 15, color: color),
            ),
          ),
        ]),
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
              border: Border.all(
                  color: color.withValues(alpha: 0.4)),
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
                    // ponytail: 摘要行仅去掉公式定界符，不做公式排版；点进 sheet 看完整渲染
                    (r.questionText ?? r.questionContent ?? r.recognizedText ?? '')
                        .replaceAll('\$\$', '').replaceAll('\$', '')
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

  /// 统计卡（设计稿 §4.3 暗色适配：白卡→bg1，仅数值上色，无彩色底）
  Widget _statCard(String label, String value, Color color) => Container(
    padding:
        const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: AppColors.bg1,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: AppColors.bg3),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value,
            style: TextStyle(
                color: color, fontSize: 22,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(label,
            style: const TextStyle(
                color: AppColors.textSecondary, fontSize: 12)),
      ],
    ),
  );

  Future<void> _showResultSheet(PaperResult r) async {
    // 上一处/下一处口径：同页结果顺序
    final samePage = (_detail?.results ?? const <PaperResult>[])
        .where((x) => x.pageId == r.pageId).toList();
    final index = samePage.indexOf(r);
    setState(() => _selectedResultId = r.resultId);
    await showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.bg1,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _ResultSheet(
        results: samePage,
        initialIndex: index < 0 ? 0 : index,
      ),
    );
    if (mounted) setState(() => _selectedResultId = null);
  }
}

/// 判定色板（图上标记与详情弹窗统一）：对绿 / 错红 / 部分蓝 / 待批琥珀
Color gradeColorOf(String grade) => switch (grade) {
  'correct' => AppColors.green,
  'wrong' => AppColors.red,
  'partial' => AppColors.blue,
  _ => AppColors.amber,
};

/// 判定符号（图上徽章）：✓ / ✕ / – / ?
IconData gradeMarkerIcon(String grade) => switch (grade) {
  'correct' => Icons.check_rounded,
  'wrong' => Icons.close_rounded,
  'partial' => Icons.remove_rounded,
  _ => Icons.help_outline_rounded,
};

/// 除 <br> 外的原始 HTML 标签（<table>/<img> 等）：flutter_markdown 会丢弃，
/// 这类内容才走本地 WebView（与网页 markdown-it 同管线）
final _rawHtmlRe = RegExp(r'<(?!br\s*/?>)[a-zA-Z]');

/// 结构化标签（表格/图片）：OCR 卷面文本会把表格压平成一行，检测它们用于题面选源
final _structuralHtmlRe =
    RegExp(r'<(table|img|thead|tbody|tr|td|th)\b', caseSensitive: false);

/// 题干选源：卷面印刷文本优先（与网页端 question_text || question_content 同口径），
/// 但题库规范题面带表格/图片而卷面文本里没有时改显题库题面——
/// 否则 OCR 压平后的卷面文本会把表格永远挡掉（upload 38470 第 5962 题实测）
String? displayQuestion(PaperResult r) {
  final text = r.questionText;
  final content = r.questionContent;
  if (content != null &&
      _structuralHtmlRe.hasMatch(content) &&
      (text == null || !_structuralHtmlRe.hasMatch(text))) {
    return content;
  }
  return text ?? content;
}

/// 富文本分流：表格/裸 HTML → 本地 WebView；普通行文/行内公式 → Text.rich 轻路径。
/// 一题最多一个 WebView（选项/答案通常是纯文本），避免挂起多个平台视图
Widget richText(String data, {double fontSize = 14}) =>
    _rawHtmlRe.hasMatch(data)
        ? MathHtmlView(data: data, fontSize: fontSize)
        : MathMarkdown(data: data, fontSize: fontSize);

/// 判定状态标签（设计稿 §5.2：浅底深字小标签，暗色适配 color@.15）
String gradeTagLabel(String grade) => switch (grade) {
  'correct' => '答对',
  'wrong' => '答错',
  'partial' => '部分对',
  _ => '批改中',
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
  String _channel = 'online'; // online | photo（对齐网页订正弹窗双 tab）
  File? _photo;
  int? _errorTag;
  bool _submitting = false;

  // ── 在线订正作答状态（B 档：按题型分流）──
  final Set<String> _optLetters = {}; // 选择（单选取第一个，多选全取）
  bool? _judge; // 判断
  final _onlineCtrl = TextEditingController(); // 计算/应用等自由文本
  List<TextEditingController> _blankCtrls = const []; // 填空每空一个

  /// 每题解析折叠状态（短解析默认展开）
  final Map<int, bool> _solutionExpanded = {};

  PaperResult get _r => widget.results[_index];

  bool get _correctable =>
      _r.grade == 'wrong' || _r.grade == 'partial';

  /// 在线作答题型：judge | single | multi | blank | text
  String get _onlineKind {
    final t = _r.questionType ?? '';
    if (t.contains('判断')) return 'judge';
    if (t.contains('选择') &&
        (_r.questionOptions?.isNotEmpty ?? false)) {
      return t.contains('多') ? 'multi' : 'single';
    }
    if (t.contains('填空')) return 'blank';
    return 'text';
  }

  @override
  void initState() {
    super.initState();
    if (_correctable) _loadCorrections();
  }

  @override
  void dispose() {
    _onlineCtrl.dispose();
    for (final c in _blankCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  void _resetOnlineAnswers() {
    _optLetters.clear();
    _judge = null;
    _onlineCtrl.clear();
    for (final c in _blankCtrls) {
      c.dispose();
    }
    _blankCtrls = const [];
  }

  void _go(int offset) {
    final next = _index + offset;
    if (next >= 0 && next < widget.results.length) {
      setState(() {
        _index = next;
        _formOpen = false;
        _photo = null;
        _errorTag = null;
        _channel = 'online';
        _resetOnlineAnswers();
        _corrections = const [];
      });
      if (_correctable) _loadCorrections();
    }
  }

  /// 解析展开态：≤100 字默认直接展示（设计稿 §8.1）
  bool _isSolutionExpanded(PaperResult r) =>
      _solutionExpanded.putIfAbsent(
          r.resultId, () => (r.questionSolution ?? '').length <= 100);

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

  /// 填空题空数：按标准答案分隔符（，,、;；）推断，1~6；无法推断给 1 个框
  // ponytail: 启发式推断，上限 6；若后续题面带标准化空位标记，改为数空位数
  int _blankCount(PaperResult r) {
    final ans = (r.questionAnswer ?? '').replaceAll('\$', '').trim();
    if (ans.isEmpty) return 1;
    final parts = ans
        .split(RegExp(r'[，,、;；]+'))
        .where((s) => s.trim().isNotEmpty)
        .toList();
    return parts.isEmpty ? 1 : parts.length.clamp(1, 6);
  }

  void _ensureBlankCtrls() {
    final n = _blankCount(_r);
    if (_blankCtrls.length != n) {
      for (final c in _blankCtrls) {
        c.dispose();
      }
      _blankCtrls =
          List.generate(n, (_) => TextEditingController());
    }
  }

  /// 构造在线订正 payload（与考试 student_answer 同构）；null = 内容为空
  Map<String, dynamic>? _onlinePayload() {
    switch (_onlineKind) {
      case 'judge':
        final v = _judge;
        if (v == null) return null;
        return {'type': 'true_false', 'selected': v};
      case 'single':
      case 'multi':
        if (_optLetters.isEmpty) return null;
        return {'selectedAnswers': _optLetters.toList()..sort()};
      case 'blank':
        final ans = _blankCtrls
            .map((c) => c.text.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        if (ans.isEmpty) return null;
        return {'answers': ans};
      default:
        final t = _onlineCtrl.text.trim();
        if (t.isEmpty) return null;
        return {'text': t};
    }
  }

  Future<void> _submitOnline() async {
    final payload = _onlinePayload();
    if (payload == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先完成作答再提交')));
      return;
    }
    setState(() => _submitting = true);
    try {
      final res = await SemecTeachingApi.instance
          .submitOnlinePaperCorrection(
        _r.resultId,
        answerPayload: payload,
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
      setState(() {
        _formOpen = false;
        _errorTag = null;
        _resetOnlineAnswers();
      });
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

  Widget _corrTag(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: AppColors.amber.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(text, style: const TextStyle(
        color: AppColors.amber, fontSize: 11, fontWeight: FontWeight.w600)),
  );

  /// 在线作答区：选择点选 / 判断对错 / 填空逐空 / 其他题型多行文本
  Widget _buildOnlineAnswerFields() {
    switch (_onlineKind) {
      case 'judge':
        return Row(children: [
          Expanded(child: _judgeTile(true, '正确', Icons.check_rounded)),
          const SizedBox(width: 10),
          Expanded(child: _judgeTile(false, '错误', Icons.close_rounded)),
        ]);
      case 'single':
      case 'multi':
        final multi = _onlineKind == 'multi';
        final opts = _r.questionOptions ?? const [];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (multi)
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Text('多选题，可点选多个选项',
                    style: TextStyle(
                        color: AppColors.textMuted, fontSize: 12)),
              ),
            for (var i = 0; i < opts.length; i++)
              _optionTile(opts[i], i, multi),
          ],
        );
      case 'blank':
        _ensureBlankCtrls();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < _blankCtrls.length; i++)
              Padding(
                padding: EdgeInsets.only(
                    bottom: i == _blankCtrls.length - 1 ? 0 : 8),
                child: TextField(
                  controller: _blankCtrls[i],
                  style: const TextStyle(fontSize: 14),
                  decoration:
                      InputDecoration(hintText: '第 ${i + 1} 空'),
                ),
              ),
          ],
        );
      default:
        return TextField(
          controller: _onlineCtrl,
          minLines: 3,
          maxLines: 6,
          style: const TextStyle(fontSize: 14),
          decoration: const InputDecoration(
            hintText: '写下你的订正过程或答案',
          ),
        );
    }
  }

  Widget _judgeTile(bool v, String label, IconData icon) {
    final selected = _judge == v;
    final color = v ? AppColors.green : AppColors.red;
    return Material(
      color: selected
          ? color.withValues(alpha: 0.15)
          : AppColors.bg2,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: _submitting ? null : () => setState(() => _judge = v),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: selected ? color : AppColors.bg3,
                width: selected ? 1.5 : 1),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center,
              children: [
            Icon(icon, size: 18,
                color: selected ? color : AppColors.textSecondary),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    color: selected
                        ? color
                        : AppColors.textSecondary,
                    fontSize: 14,
                    fontWeight:
                        selected ? FontWeight.w700 : FontWeight.w500)),
          ]),
        ),
      ),
    );
  }

  String _optionLetter(String opt, int i) {
    final m = RegExp(r'^([A-Za-z])').firstMatch(opt.trim());
    return m != null
        ? m.group(1)!.toUpperCase()
        : String.fromCharCode(65 + i);
  }

  Widget _optionTile(String opt, int i, bool multi) {
    final letter = _optionLetter(opt, i);
    final selected = _optLetters.contains(letter);
    final body = opt
        .trim()
        .replaceFirst(RegExp(r'^[A-Za-z][\.．、\)）:：\s]*'), '')
        .trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? AppColors.blue.withValues(alpha: 0.12)
            : AppColors.bg2,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _submitting
              ? null
              : () => setState(() {
                    if (multi) {
                      selected
                          ? _optLetters.remove(letter)
                          : _optLetters.add(letter);
                    } else {
                      _optLetters
                        ..clear()
                        ..add(letter);
                    }
                  }),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: selected ? AppColors.blue : AppColors.bg3,
                  width: selected ? 1.5 : 1),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Container(
                width: 24, height: 24,
                decoration: BoxDecoration(
                  color: selected
                      ? AppColors.blue
                      : Colors.transparent,
                  shape: multi
                      ? BoxShape.rectangle
                      : BoxShape.circle,
                  borderRadius:
                      multi ? BorderRadius.circular(5) : null,
                  border: Border.all(
                      color: selected
                          ? AppColors.blue
                          : AppColors.textMuted),
                ),
                alignment: Alignment.center,
                child: selected && multi
                    ? const Icon(Icons.check,
                        size: 16, color: AppColors.bg0)
                    : Text(letter,
                        style: TextStyle(
                            color: selected
                                ? AppColors.bg0
                                : AppColors.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 10),
              Expanded(child: richText(body, fontSize: 14)),
            ]),
          ),
        ),
      ),
    );
  }

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
          if (_corrections.length < 3) ...[
            OutlinedButton(
              onPressed: _submitting
                  ? null
                  : () => setState(() {
                        _formOpen = true;
                        _channel = 'photo';
                      }),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textSecondary,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              child: const Text('拍照订正', style: TextStyle(fontSize: 12)),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: _submitting
                  ? null
                  : () => setState(() {
                        _formOpen = true;
                        _channel = 'online';
                      }),
              style: ElevatedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: Text(_corrections.isEmpty ? '在线订正' : '再做一遍',
                  style: const TextStyle(fontSize: 12)),
            ),
          ] else
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
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                  value: 'online',
                  label: Text('在线作答'),
                  icon: Icon(Icons.edit_note, size: 18)),
              ButtonSegment(
                  value: 'photo',
                  label: Text('重做拍照'),
                  icon: Icon(Icons.camera_alt_outlined, size: 18)),
            ],
            selected: {_channel},
            showSelectedIcon: false,
            onSelectionChanged: _submitting
                ? null
                : (v) => setState(() => _channel = v.first),
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              foregroundColor: WidgetStateProperty.resolveWith((states) =>
                  states.contains(WidgetState.selected)
                      ? AppColors.bg0
                      : AppColors.textSecondary),
            ),
          ),
          const SizedBox(height: 10),
          if (_channel == 'online')
            _buildOnlineAnswerFields()
          else ...[
            Row(children: [
              OutlinedButton.icon(
                onPressed: _submitting
                    ? null : () => _pickPhoto(ImageSource.camera),
                icon: const Icon(Icons.camera_alt_outlined, size: 16),
                label: const Text('拍照上传'),
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
              Text(
                  '已选择：${_photo!.path.split(Platform.pathSeparator).last}',
                  style: const TextStyle(
                      color: AppColors.textMuted, fontSize: 12)),
            ],
          ],
          const SizedBox(height: 10),
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
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(
              onPressed: _submitting
                  ? null : () => setState(() => _formOpen = false),
              child: const Text('取消'),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: _submitting
                  ? null
                  : (_channel == 'online'
                      ? _submitOnline
                      : _submitCorrection),
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

  /// 统一内容区块（设计稿 §7：浅底 + 3px 左状态边线 + 6px 圆角）
  Widget _sectionBlock({
    required String label,
    required Color color,
    required Widget body,
  }) =>
      Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.bg2,
          borderRadius: BorderRadius.circular(6),
          border: Border(left: BorderSide(color: color, width: 3)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          body,
        ]),
      );

  /// 题目解析：细分隔线折叠面板（设计稿 §8），短解析默认展开
  Widget _buildSolutionTile(PaperResult r) {
    final expanded = _isSolutionExpanded(r);
    return Container(
      margin: const EdgeInsets.only(top: 4),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.bg3)),
      ),
      child: Theme(
        // 折叠区内不留 Material 默认分割线，只用上方那一条
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          dense: true,
          initiallyExpanded: expanded,
          onExpansionChanged: (v) =>
              setState(() => _solutionExpanded[r.resultId] = v),
          leading: null,
          title: const Text('题目解析',
              style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          trailing: Icon(
              expanded
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
              color: AppColors.textSecondary),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: richText(r.questionSolution!, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _navButton(IconData icon, bool enabled, VoidCallback? onTap) =>
      Material(
        color: enabled ? AppColors.bg2 : AppColors.bg2.withValues(alpha: 0.5),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onTap : null,
          child: SizedBox(
            width: 40, height: 40,
            child: Icon(icon, size: 22,
                color: enabled ? AppColors.textPrimary : AppColors.textMuted),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final r = _r;
    final color = gradeColorOf(r.grade);
    final screenH = MediaQuery.of(context).size.height;
    final question = displayQuestion(r);
    final hasMyAnswer =
        r.recognizedText != null && r.recognizedText!.trim().isNotEmpty;
    final feedbackText = [
      if ((r.feedback ?? '').isNotEmpty) r.feedback,
      // 判对不显示原因（与网页端一致）
      if (r.grade != 'correct' && (r.reason ?? '').isNotEmpty) r.reason,
    ].whereType<String>().join('\n');
    final isEmpty = question == null && !hasMyAnswer;

    return SizedBox(
      height: screenH * 0.82,
      child: GestureDetector(
        // 左右滑动切换上一/下一题
        onHorizontalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if (v < -200) _go(1);
          if (v > 200) _go(-1);
        },
        child: Column(children: [
          // ── 抓手 ──
          Container(
            margin: const EdgeInsets.only(top: 8, bottom: 4),
            width: 36, height: 4,
            decoration: BoxDecoration(
              color: AppColors.bg3,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // ── 题目头（设计稿 §5.2：题号+状态标签同行，右侧得分）──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 10),
            child: Column(children: [
              Row(children: [
                Text('第 ${_index + 1} 题',
                    style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(gradeTagLabel(r.grade),
                      style: TextStyle(
                          color: color,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ),
                const Spacer(),
                if (r.score != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text(
                        '得分 ${r.score!.toStringAsFixed(r.score! % 1 == 0 ? 0 : 1)}'
                        '${r.maxScore != null ? '/${r.maxScore!.toStringAsFixed(r.maxScore! % 1 == 0 ? 0 : 1)}' : ''}',
                        style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                  )
                else
                  const Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: Text('得分暂不可用',
                        style: TextStyle(
                            color: AppColors.textMuted, fontSize: 12)),
                  ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  color: AppColors.textMuted,
                  onPressed: () => Navigator.pop(context),
                ),
              ]),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                    '${r.questionType ?? '题目'} · 本页第 ${_index + 1} / '
                    '${widget.results.length} 处',
                    style: const TextStyle(
                        color: AppColors.textMuted, fontSize: 12)),
              ),
            ]),
          ),
          const Divider(height: 1, thickness: 1, color: AppColors.bg3),
          // ── 内容区 ──
          Expanded(child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            children: [
              if (isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Column(children: [
                    Icon(Icons.hourglass_bottom,
                        size: 36, color: AppColors.textMuted),
                    SizedBox(height: 10),
                    Text('该题仍在识别中，请稍后再看',
                        style: TextStyle(
                            color: AppColors.textMuted, fontSize: 13)),
                  ]),
                )
              else ...[
                if (question != null) ...[
                  const Text('题目',
                      style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  // 完整题干（含公式/表格/图片），不截断、不限高（设计稿 §6.1）
                  // 含 <table> 等裸 HTML 时走本地 WebView（与网页同管线）
                  richText(question, fontSize: 15),
                  const SizedBox(height: 16),
                ],
                if (hasMyAnswer)
                  _sectionBlock(
                    label: '我的答案',
                    color: AppColors.textSecondary,
                    body: Text(_parseRecognized(r.recognizedText),
                        style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 14, height: 1.65)),
                  ),
                if ((r.questionAnswer ?? '').isNotEmpty)
                  _sectionBlock(
                    label: '正确答案',
                    color: AppColors.blue,
                    // 参考答案含 $LaTeX$
                    body: richText(r.questionAnswer!, fontSize: 14),
                  ),
                if (feedbackText.isNotEmpty)
                  _sectionBlock(
                    label: '错误分析',
                    color: AppColors.amber,
                    body: Text(feedbackText,
                        style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 14, height: 1.65)),
                  ),
                if ((r.questionSolution ?? '').trim().isNotEmpty)
                  _buildSolutionTile(r),
              ],
              if (_correctable) _buildCorrectionSection(),
            ],
          )),
          // ── 底部切题导航 ──
          const Divider(height: 1, thickness: 1, color: AppColors.bg3),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _navButton(Icons.chevron_left_rounded,
                    _index > 0, () => _go(-1)),
                Text('${_index + 1} / ${widget.results.length}',
                    style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 13, fontWeight: FontWeight.w600)),
                _navButton(Icons.chevron_right_rounded,
                    _index < widget.results.length - 1, () => _go(1)),
              ],
            ),
          ),
          const SafeArea(top: false, child: SizedBox.shrink()),
        ]),
      ),
    );
  }
}
