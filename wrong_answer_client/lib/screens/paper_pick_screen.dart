// lib/screens/paper_pick_screen.dart
// 纸面作业链路入口：从「我的作业」选卷，或自由上传（不关联作业）
import 'package:flutter/material.dart';
import '../api/semec_teaching_api.dart';
import '../models/paper_models.dart';
import '../utils/db_helper.dart';
import '../utils/theme.dart';
import 'paper_capture_screen.dart';
import 'paper_result_screen.dart';
import 'paper_task_list_screen.dart';

class PaperPickScreen extends StatefulWidget {
  const PaperPickScreen({super.key});

  @override
  State<PaperPickScreen> createState() => _PaperPickScreenState();
}

class _PaperPickScreenState extends State<PaperPickScreen> {
  List<PaperAssignment> _assignments = [];
  List<Map<String, dynamic>> _pending = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final list = await SemecTeachingApi.instance.getPaperAssignments();
      var pending = await DbHelper.instance.listPendingUploads();
      pending = await _reconcilePending(pending);
      if (mounted) {
        setState(() {
          _assignments = list;
          _pending = pending;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  /// 用服务端任务列表对账本地 pending：命中且终态→删；命中且非终态→刷新状态。
  /// ponytail: 列表接口仅回最近 20 条，未命中不代表不存在，故保留本地记录
  Future<List<Map<String, dynamic>>> _reconcilePending(
      List<Map<String, dynamic>> pending) async {
    if (pending.isEmpty) return pending;
    Map<int, PaperUploadRow> byId;
    try {
      final rows = await SemecTeachingApi.instance.listPaperUploads();
      byId = {for (final r in rows) r.id: r};
    } catch (_) {
      return pending; // 离线/请求失败：维持本地
    }
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
    if (mounted) _load();
  }

  /// 作业卡：有处理中任务→直达结果页，否则→去拍照上传
  void _openAssignment(PaperAssignment a) {
    final matches =
        _pending.where((p) => p['assign_id'] == a.assignId).toList();
    if (matches.isNotEmpty) {
      final p = matches.first;
      Navigator.push(context, MaterialPageRoute(builder: (_) => PaperResultScreen(
        uploadId: p['upload_id'] as int,
        uploadNo: p['upload_no'] as String?,
      )));
    } else {
      _go(assignment: a);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg0,
      appBar: AppBar(title: const Text('纸面作业')),
      body: RefreshIndicator(
        onRefresh: _load,
        color: AppColors.amber,
        backgroundColor: AppColors.bg2,
        child: _buildList(),
      ),
    );
  }

  Widget _buildList() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(
          color: AppColors.amber, strokeWidth: 2));
    }
    if (_error != null) {
      return ListView(children: [
        const SizedBox(height: 80),
        Icon(Icons.error_outline, size: 40, color: AppColors.red),
        const SizedBox(height: 12),
        Text(_error!, textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
        const SizedBox(height: 12),
        TextButton(onPressed: _load, child: const Text('重试')),
      ]);
    }
    // 始终可滚动作「自由上传」入口 + 作业列表
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: [
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
          Material(
            color: AppColors.amber.withOpacity(0.12),
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => Navigator.push(context, MaterialPageRoute(
                  builder: (_) => const PaperTaskListScreen())),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border:
                      Border.all(color: AppColors.amber.withOpacity(0.5)),
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
          ),
        ],
        const SizedBox(height: 20),
        const Text('我的作业', style: AppText.label),
        const SizedBox(height: 8),
        if (_assignments.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Text('暂无待交作业', textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
          ),
        ..._assignments.map((a) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Material(
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
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(a.examTitle.isNotEmpty ? a.examTitle
                              : (a.paperTitle ?? '未命名作业'),
                              style: const TextStyle(
                                  color: AppColors.textPrimary,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 4),
                          Text([
                            if (a.subject != null) a.subject,
                            if (a.gradeName != null) a.gradeName,
                            if (a.teacherName != null) a.teacherName,
                          ].whereType<String>().join(' · '),
                              style: const TextStyle(
                                  color: AppColors.textMuted, fontSize: 12)),
                          if (a.endTime != null) ...[
                            const SizedBox(height: 4),
                            Text('截止 ${_fmtTime(a.endTime!)}',
                                style: const TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 12)),
                          ],
                        ],
                      ),
                    ),
                    if (_pending.any((p) => p['assign_id'] == a.assignId))
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.amber.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text('处理中',
                            style: TextStyle(
                                color: AppColors.amber, fontSize: 11,
                                fontWeight: FontWeight.w600)),
                      ),
                    if (a.uploadCount > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.green.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('已交 $a.uploadCount 次',
                            style: const TextStyle(
                                color: AppColors.green, fontSize: 11,
                                fontWeight: FontWeight.w600)),
                      ),
                    const SizedBox(width: 8),
                    const Icon(Icons.chevron_right,
                        size: 18, color: AppColors.textMuted),
                  ],
                ),
              ),
            ),
          ),
        )),
      ],
    );
  }

  String _fmtTime(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    final local = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.month}/${local.day} ${two(local.hour)}:${two(local.minute)}';
  }
}
