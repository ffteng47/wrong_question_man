// lib/screens/paper_task_list_screen.dart
// 我的判题任务列表：非终态任务 30s 轮询刷新
import 'dart:async';
import 'package:flutter/material.dart';
import '../api/semec_teaching_api.dart';
import '../models/paper_models.dart';
import '../utils/theme.dart';
import 'paper_result_screen.dart';

class PaperTaskListScreen extends StatefulWidget {
  const PaperTaskListScreen({super.key});

  @override
  State<PaperTaskListScreen> createState() => _PaperTaskListScreenState();
}

/// 内存缓存：从详情返回/再次进入时秒开，后台静默刷新
List<PaperUploadRow>? _taskListCache;

class _PaperTaskListScreenState extends State<PaperTaskListScreen> {
  List<PaperUploadRow> _rows = [];
  bool _loading = true;
  String? _error;
  Timer? _timer;

  static const _statusColor = {
    '完成': AppColors.green,
    '部分完成': AppColors.amber,
    '等待人工确认': AppColors.amber,
    '处理失败': AppColors.red,
  };

  @override
  void initState() {
    super.initState();
    if (_taskListCache != null) {
      _rows = _taskListCache!;
      _loading = false;
      _load(); // 先秒开，后台静默刷新
    } else {
      _load(initial: true);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool initial = false, bool silent = false}) async {
    try {
      final list = await SemecTeachingApi.instance.listPaperUploads();
      _taskListCache = list;
      if (!mounted) return;
      setState(() {
        _rows = list;
        _loading = false;
        _error = null;
      });
      _timer?.cancel();
      if (list.any((r) => !r.isTerminal)) {
        _timer = Timer.periodic(const Duration(seconds: 30), (_) => _load());
      }
    } catch (e) {
      if (!mounted) return;
      // 静默/缓存场景失败：保留现有列表，不弹错误页
      if (initial && _taskListCache == null) {
        setState(() { _loading = false; _error = e.toString(); });
      } else {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg0,
      appBar: AppBar(title: const Text('我的作业任务')),
      body: RefreshIndicator(
        onRefresh: _load,
        color: AppColors.amber,
        backgroundColor: AppColors.bg2,
        child: _loading
            ? const Center(child: CircularProgressIndicator(
                color: AppColors.amber, strokeWidth: 2))
            : _error != null
                ? ListView(children: [
                    const SizedBox(height: 100),
                    Center(child: Text(_error!,
                        style: const TextStyle(
                            color: AppColors.red, fontSize: 13))),
                    Center(child: TextButton(
                        onPressed: () => _load(initial: true),
                        child: const Text('重试'))),
                  ])
                : _rows.isEmpty
                    ? ListView(children: const [
                        SizedBox(height: 120),
                        Center(
                          child: Text('还没有提交过作业',
                              style: TextStyle(
                                  color: AppColors.textMuted, fontSize: 13)),
                        ),
                      ])
                    : ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(16),
                        children: [
                          _buildHint(),
                          ..._rows.map(_rowCard),
                        ],
                      ),
      ),
    );
  }

  /// 区分本页（自己的上传记录）与「我的作业」（老师布置的全部作业目录）
  Widget _buildHint() => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.bg1,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.bg3),
        ),
        child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.info_outline, size: 15, color: AppColors.textMuted),
          SizedBox(width: 8),
          Expanded(child: Text(
              '这里只列出你已上传过的作业记录；老师布置给你的全部作业（含未提交）'
              '请回到「我的作业」查看。',
              style: TextStyle(
                  color: AppColors.textMuted, fontSize: 11.5, height: 1.45))),
        ]),
      );

  Widget _rowCard(PaperUploadRow r) {
    final color = _statusColor[r.status] ?? AppColors.textSecondary;
    final processing = !r.isTerminal;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppColors.bg1,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () async {
            await Navigator.push(context, MaterialPageRoute(
                builder: (_) => PaperResultScreen(
                    uploadId: r.id, uploadNo: r.uploadNo)));
            // 返回不重拉：30s 轮询 + 下拉刷新已覆盖状态变化
          },
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
                      Text(r.paperTitle ?? r.uploadNo,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text('${r.uploadNo} · ${r.totalPages} 页',
                          style: const TextStyle(
                              color: AppColors.textMuted, fontSize: 12)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (processing)
                  const SizedBox(
                      width: 14, height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.amber))
                else
                  Icon(
                    r.status == '完成' ? Icons.check_circle_outline
                        : r.status == '处理失败' ? Icons.error_outline
                            : Icons.hourglass_bottom,
                    size: 16, color: color),
                const SizedBox(width: 6),
                Text(r.status,
                    style: TextStyle(
                        color: color, fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
