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
    _load(initial: true);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool initial = false}) async {
    try {
      final list = await SemecTeachingApi.instance.listPaperUploads();
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
      setState(() {
        _loading = false;
        if (initial) _error = e.toString();
      });
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
                          child: Text('还没有提交过纸面作业',
                              style: TextStyle(
                                  color: AppColors.textMuted, fontSize: 13)),
                        ),
                      ])
                    : ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(16),
                        itemCount: _rows.length,
                        itemBuilder: (_, i) => _rowCard(_rows[i]),
                      ),
      ),
    );
  }

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
            _load();
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
