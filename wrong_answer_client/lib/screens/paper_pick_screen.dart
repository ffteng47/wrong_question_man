// lib/screens/paper_pick_screen.dart
// 纸面作业链路入口：从「我的作业」选卷，或自由上传（不关联作业）
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../api/semec_teaching_api.dart';
import '../models/paper_models.dart';
import '../utils/db_helper.dart';
import '../utils/platform_open_file.dart';
import '../utils/theme.dart';
import 'paper_capture_screen.dart';
import 'paper_result_screen.dart';
import 'paper_task_list_screen.dart';

const _kPageSize = 5;

/// 内存缓存：再次进入/从详情返回时秒开，随后后台静默刷新
List<PaperAssignment>? _cacheAssignments;
List<Map<String, dynamic>>? _cachePending;
Map<int, PaperUploadRow>? _cacheLatest;

class PaperPickScreen extends StatefulWidget {
  const PaperPickScreen({super.key});

  @override
  State<PaperPickScreen> createState() => _PaperPickScreenState();
}

class _PaperPickScreenState extends State<PaperPickScreen> {
  List<PaperAssignment> _assignments = [];
  List<Map<String, dynamic>> _pending = [];

  /// 每个作业最近一次上传（uploads 接口按 id DESC，putIfAbsent 取最新）
  final Map<int, PaperUploadRow> _latestByAssign = {};

  int _visibleCount = _kPageSize;
  bool _loading = true;
  String? _error;

  /// 正在下载 PDF 的作业（防重复点击 + 卡片上转圈）
  final Set<int> _pdfLoading = {};

  /// 类型徽章配色（考试蓝 / 作业琥珀 / 练习绿 / 口算灰）
  static const _typeColors = {
    'exam': AppColors.blue,
    'homework': AppColors.amber,
    'practice': AppColors.green,
    'mental': AppColors.textSecondary,
  };

  /// 作业类型卡片：下载卷面 PDF 后调起系统查看器（对齐网页端「下载PDF试卷」）
  Future<void> _downloadPdf(PaperAssignment a) async {
    if (_pdfLoading.contains(a.assignId)) return;
    setState(() => _pdfLoading.add(a.assignId));
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await SemecTeachingApi.instance
          .downloadAssignmentPdf(a.assignId);
      final dir = await getTemporaryDirectory();
      final title = (a.paperTitle != null && a.paperTitle!.isNotEmpty)
          ? a.paperTitle!
          : (a.examTitle.isNotEmpty ? a.examTitle : '试卷');
      final safe = title
          .replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_')
          .replaceAll(RegExp(r'_+'), '_');
      // 固定文件名含 assignId：重复下载直接覆盖，临时目录不堆积
      final f = File(
          '${dir.path}${Platform.pathSeparator}paper_${a.assignId}_$safe.pdf');
      await f.writeAsBytes(bytes, flush: true);
      final err =
          await PlatformOpenFile.open(f.path, mimeType: 'application/pdf');
      if (err != null) {
        messenger.showSnackBar(
            SnackBar(content: Text('PDF 已下载，但$err')));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _pdfLoading.remove(a.assignId));
    }
  }

  @override
  void initState() {
    super.initState();
    if (_applyCache()) {
      _load(silent: true); // 有缓存：先秒开，后台静默刷新
    } else {
      _load();
    }
  }

  /// 命中缓存则直接渲染，返回是否有缓存
  bool _applyCache() {
    final a = _cacheAssignments, p = _cachePending, l = _cacheLatest;
    if (a == null || p == null || l == null) return false;
    _assignments = a;
    _pending = p;
    _latestByAssign
      ..clear()
      ..addAll(l);
    _loading = false;
    return true;
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() { _loading = true; _error = null; _visibleCount = _kPageSize; });
    }
    try {
      final results = await Future.wait([
        SemecTeachingApi.instance.getPaperAssignments(),
        SemecTeachingApi.instance.listPaperUploads()
            .then((rows) => rows, onError: (_) => <PaperUploadRow>[]),
        DbHelper.instance.listPendingUploads(),
      ]);
      final list = results[0] as List<PaperAssignment>;
      final uploads = results[1] as List<PaperUploadRow>;
      var pending = results[2] as List<Map<String, dynamic>>;

      _latestByAssign.clear();
      for (final u in uploads) {
        final aid = u.assignId;
        if (aid != null) _latestByAssign.putIfAbsent(aid, () => u);
      }
      pending = await _reconcilePending(pending, uploads);

      _cacheAssignments = list;
      _cachePending = pending;
      _cacheLatest = Map<int, PaperUploadRow>.from(_latestByAssign);

      if (mounted) {
        setState(() {
          _assignments = list;
          _pending = pending;
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      // 静默刷新失败：保留缓存不动；首次加载才显示错误页
      if (!silent && mounted) {
        setState(() { _error = e.toString(); _loading = false; });
      }
    }
  }

  /// 用服务端任务列表对账本地 pending：命中且终态→删；命中且非终态→刷新状态。
  /// ponytail: 列表接口仅回最近 20 条，未命中不代表不存在，故保留本地记录
  Future<List<Map<String, dynamic>>> _reconcilePending(
      List<Map<String, dynamic>> pending,
      List<PaperUploadRow> uploads) async {
    if (pending.isEmpty) return pending;
    final byId = {for (final r in uploads) r.id: r};
    final result = <Map<String, dynamic>>[];
    for (final p in pending) {
      final id = p['upload_id'] as int?;
      if (id == null) { result.add(p); continue; }
      final server = byId[id];
      if (server != null) {
        if (server.isTerminal) {
          await DbHelper.instance.deletePendingUpload(id);
          continue;
        }
        await DbHelper.instance.upsertPendingUpload(
            uploadId: id, status: server.status);
        result.add({...p, 'status': server.status});
      } else {
        result.add(p);
      }
    }
    return result;
  }

  Future<void> _go({PaperAssignment? assignment}) async {
    await Navigator.push(context,
      MaterialPageRoute(builder: (_) =>
          PaperCaptureScreen(assignment: assignment)));
    // 拍完新照片：静默刷新即可，不回退到全屏 loading
    if (mounted) _load(silent: true);
  }

  /// 作业卡：处理中/已交→直达最近一次结果页，从未交过→去拍照上传
  /// ponytail: 仅能识别最近 20 次上传内的作业，更早的历史会走拍照（可经任务列表页查看）
  void _openAssignment(PaperAssignment a) {
    final matches =
        _pending.where((p) => p['assign_id'] == a.assignId).toList();
    if (matches.isNotEmpty) {
      final p = matches.first;
      Navigator.push(context, MaterialPageRoute(builder: (_) => PaperResultScreen(
        uploadId: p['upload_id'] as int,
        uploadNo: p['upload_no'] as String?,
      )));
      return;
    }
    final row = _latestByAssign[a.assignId];
    if (row != null) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => PaperResultScreen(
        uploadId: row.id, uploadNo: row.uploadNo,
      )));
    } else {
      _go(assignment: a);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg0,
      appBar: AppBar(title: const Text('我的作业')),
      body: RefreshIndicator(
        onRefresh: _load,
        color: AppColors.amber,
        backgroundColor: AppColors.bg2,
        child: _loading || _error != null ? _buildStatus() : _buildList(),
      ),
    );
  }

  Widget _buildStatus() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(
          color: AppColors.amber, strokeWidth: 2));
    }
    return ListView(children: [
      const SizedBox(height: 80),
      const Icon(Icons.error_outline, size: 40, color: AppColors.red),
      const SizedBox(height: 12),
      Text(_error!, textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
      const SizedBox(height: 12),
      Center(child: TextButton(onPressed: _load, child: const Text('重试'))),
    ]);
  }

  Widget _buildList() {
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverToBoxAdapter(child: Column(children: [
            OutlinedButton.icon(
              onPressed: () => _go(),
              icon: const Icon(Icons.upload_file,
                  size: 18, color: AppColors.textSecondary),
              label: const Text('自由上传（不关联作业）',
                  style: TextStyle(color: AppColors.textSecondary)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppColors.bg3),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
            if (_pending.isNotEmpty) ...[
              const SizedBox(height: 12),
              _buildPendingBanner(),
            ],
            const SizedBox(height: 20),
            Row(children: [
              const Text('我的作业', style: AppText.label),
              const Spacer(),
              Text('共 ${_assignments.length} 项',
                  style: const TextStyle(
                      color: AppColors.textMuted, fontSize: 12)),
            ]),
            if (_assignments.isNotEmpty) ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(_typeSummary(),
                    style: const TextStyle(
                        color: AppColors.textMuted, fontSize: 11.5)),
              ),
            ],
            const SizedBox(height: 8),
          ])),
        ),
        if (_assignments.isEmpty)
          const SliverToBoxAdapter(child: Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Text('暂无待交作业', textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
          ))
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList.builder(
              itemCount: _visibleCount.clamp(0, _assignments.length),
              itemBuilder: (_, i) =>
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _buildCard(_assignments[i]),
                  ),
            ),
          ),
        if (_visibleCount < _assignments.length)
          SliverPadding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            sliver: SliverToBoxAdapter(
              child: Center(child: TextButton(
                onPressed: () =>
                    setState(() => _visibleCount += _kPageSize),
                child: Text('加载更多'
                    '（还剩 ${_assignments.length - _visibleCount} 项）'),
              )),
            ),
          )
        else
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
      ],
    );
  }

  Widget _buildPendingBanner() {
    return Material(
      color: AppColors.amber.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => Navigator.push(context, MaterialPageRoute(
            builder: (_) => const PaperTaskListScreen())),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.amber.withValues(alpha: 0.5)),
          ),
          child: Row(children: [
            const Icon(Icons.watch_later_outlined,
                size: 18, color: AppColors.amber),
            const SizedBox(width: 8),
            Expanded(child: Text('未完成上传（${_pending.length}）',
                style: const TextStyle(
                    color: AppColors.amber,
                    fontSize: 13,
                    fontWeight: FontWeight.w600))),
            const Icon(Icons.chevron_right,
                size: 18, color: AppColors.amber),
          ]),
        ),
      ),
    );
  }

  Widget _buildCard(PaperAssignment a) {
    final pending = _pending.any((p) => p['assign_id'] == a.assignId);
    // 最近一次上传：本地有 pending，或服务端最新记录非终态 → 处理中；终态失败 → 处理失败
    final latest = _latestByAssign[a.assignId];
    final failed = latest?.status == '处理失败';
    final processing = pending || (latest != null && !latest.isTerminal);
    // 状态徽章文案与颜色（优先级：处理中 > 处理失败 > 已交 N 次 > 未提交）
    final String chipText = processing
        ? '处理中'
        : failed
            ? '处理失败'
            : a.uploadCount > 0
                ? '已交 ${a.uploadCount} 次'
                : '未提交';
    final Color chipColor = processing
        ? AppColors.amber
        : failed
            ? AppColors.red
            : a.uploadCount > 0
                ? AppColors.green
                : AppColors.textMuted;
    return Material(
      color: AppColors.bg1,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _openAssignment(a),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.bg3),
          ),
          // 纵向布局：标题独占一行，状态在底部专属行，不再挤压标题
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _typeChip(a),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        a.examTitle.isNotEmpty ? a.examTitle
                            : (a.paperTitle ?? '未命名作业'),
                        maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 15,
                            height: 1.3,
                            fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.chevron_right,
                      size: 18, color: AppColors.textMuted),
                ],
              ),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(child: Text([
                  if (a.subject != null) a.subject,
                  if (a.gradeName != null) a.gradeName,
                  if (a.teacherName != null) a.teacherName,
                ].whereType<String>().join(' · '),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.textMuted, fontSize: 12))),
                // 仅「作业」类型：对齐网页端下钻页的下载 PDF 试卷
                if (a.isHomework) _pdfButton(a),
              ]),
              const SizedBox(height: 10),
              // 底部状态行：左截止时间，右状态徽章 + 再拍
              Row(
                children: [
                  if (a.endTime != null) ...[
                    const Icon(Icons.event_busy,
                        size: 13, color: AppColors.textSecondary),
                    const SizedBox(width: 4),
                    Text('截止 ${_fmtTime(a.endTime!)}',
                        style: const TextStyle(
                            color: AppColors.textSecondary, fontSize: 12)),
                  ] else
                    const Text('无截止时间',
                        style: TextStyle(
                            color: AppColors.textMuted, fontSize: 12)),
                  const Spacer(),
                  _statusChip(chipText, chipColor),
                  // 重新上传入口：处理中不允许，避免再开一条任务；失败时红色引导重拍
                  if (!processing && (a.uploadCount > 0 || failed))
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => _go(assignment: a),
                      child: Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.add_a_photo_outlined,
                              size: 15, color: chipColor),
                          const SizedBox(width: 3),
                          Text('再拍',
                              style: TextStyle(
                                  color: chipColor,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600)),
                        ]),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 标题左侧类型徽章（考试/作业/练习/口算）
  Widget _typeChip(PaperAssignment a) {
    final color = _typeColors[a.paperType] ?? AppColors.textMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      margin: const EdgeInsets.only(top: 2),
      decoration: BoxDecoration(
        color: AppColors.bg2,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(a.paperTypeLabel,
          style: TextStyle(
              color: color, fontSize: 10.5, fontWeight: FontWeight.w600)),
    );
  }

  /// 作业类型卡片的 PDF 下载入口（下载中防重复点击）
  Widget _pdfButton(PaperAssignment a) {
    final busy = _pdfLoading.contains(a.assignId);
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: busy ? null : () => _downloadPdf(a),
      child: Padding(
        padding: const EdgeInsets.only(left: 8, top: 2, bottom: 2),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          busy
              ? const SizedBox(width: 13, height: 13,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.blue))
              : const Icon(Icons.download_outlined,
                  size: 14, color: AppColors.blue),
          const SizedBox(width: 3),
          Text(busy ? '下载中' : 'PDF',
              style: const TextStyle(
                  color: AppColors.blue,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  /// 卡片底部状态小徽章
  Widget _statusChip(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text,
            style: TextStyle(
                color: color, fontSize: 11, fontWeight: FontWeight.w600)),
      );

  /// 头部「考试 7 · 作业 4 …」统计串（只列出现有类型，顺序固定）
  String _typeSummary() {
    const order = [
      ['exam', '考试'], ['homework', '作业'],
      ['practice', '练习'], ['mental', '口算'],
    ];
    const known = {'exam', 'homework', 'practice', 'mental'};
    final counts = <String, int>{};
    var other = 0;
    for (final a in _assignments) {
      final t = a.paperType;
      if (t == null || !known.contains(t)) { other++; continue; }
      counts[t] = (counts[t] ?? 0) + 1;
    }
    final parts = [
      for (final o in order)
        if ((counts[o[0]] ?? 0) > 0) '${o[1]} ${counts[o[0]]}',
      if (other > 0) '试卷 $other',
    ];
    return parts.join(' · ');
  }

  String _fmtTime(String iso) {
    final dt = DateTime.parse(iso).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.month}/${dt.day} ${two(dt.hour)}:${two(dt.minute)}';
  }
}
