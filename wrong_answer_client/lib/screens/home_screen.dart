// lib/screens/home_screen.dart
import 'package:flutter/material.dart';
import '../models/wrong_answer_record.dart';
import '../utils/db_helper.dart';
import '../utils/draft_helper.dart';
import '../utils/theme.dart';
import '../widgets/draft_banner.dart';
import '../widgets/record_card.dart';
import 'capture_screen.dart';
import 'detail_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<WrongAnswerRecord> _records = [];
  List<DraftTask> _drafts = [];
  Map<String, int> _stats = {};
  bool _loading = true;

  // 筛选
  String? _filterSubject;
  String? _filterGrade;
  String? _filterStatus;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final records = await DbHelper.instance.query(
      subject: _filterSubject,
      grade: _filterGrade,
      reviewStatus: _filterStatus,
    );
    final stats = await DbHelper.instance.stats();
    final drafts = await DraftHelper.instance.pendingTasks();
    if (mounted) {
      setState(() {
        _records = records;
        _stats = stats;
        _drafts = drafts;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg0,
      appBar: AppBar(
        title: const Text('错题本'),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune_outlined),
            onPressed: _showFilterSheet,
            tooltip: '筛选',
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SettingsScreen())),
            tooltip: '设置',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        color: AppColors.amber,
        backgroundColor: AppColors.bg2,
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _buildStatsRow()),
            if (_drafts.isNotEmpty)
              SliverToBoxAdapter(
                child: Column(
                  children: _drafts.map((d) => DraftBanner(
                    draft: d,
                    onResume: () => _resumeDraft(d),
                    onDiscard: () => _discardDraft(d),
                  )).toList(),
                ),
              ),
            if (_filterSubject != null ||
                _filterGrade != null ||
                _filterStatus != null)
              SliverToBoxAdapter(child: _buildFilterChips()),
            if (_loading)
              const SliverFillRemaining(
                child: Center(child: CircularProgressIndicator(
                    color: AppColors.amber, strokeWidth: 2)),
              )
            else if (_records.isEmpty && _drafts.isEmpty)
              SliverFillRemaining(child: _buildEmpty())
            else
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) => RecordCard(
                    record: _records[i],
                    onTap: () async {
                      await Navigator.push(ctx,
                          MaterialPageRoute(builder: (_) =>
                              DetailScreen(record: _records[i])));
                      _load();
                    },
                    onDelete: () => _confirmDelete(_records[i]),
                  ),
                  childCount: _records.length,
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 100)),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final added = await Navigator.push<bool>(context,
              MaterialPageRoute(builder: (_) => const CaptureScreen()));
          if (added == true) _load();
        },
        backgroundColor: AppColors.amber,
        foregroundColor: AppColors.bg0,
        icon: const Icon(Icons.add),
        label: const Text('添加错题', style: TextStyle(fontWeight: FontWeight.w600)),
      ),
    );
  }

  // ── 继续草稿 ──────────────────────────────────────────────────────────────
  Future<void> _resumeDraft(DraftTask draft) async {
    final added = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => CaptureScreen(resumeDraft: draft),
      ),
    );
    if (added == true) _load();
  }

  // ── 放弃草稿 ──────────────────────────────────────────────────────────────
  Future<void> _discardDraft(DraftTask draft) async {
    await DraftHelper.instance.delete(draft.id);
    _load();
  }

  Widget _buildStatsRow() {
    final total    = _stats['total'] ?? 0;
    final mastered = _stats['mastered'] ?? 0;
    final pending  = _stats['pending'] ?? 0;
    final rate = total > 0 ? mastered / total : 0.0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.bg1,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.bg3),
        ),
        child: Row(
          children: [
            Expanded(child: _statItem('总题数', '$total', AppColors.textPrimary)),
            _divider(),
            Expanded(child: _statItem('待复习', '$pending', AppColors.textMuted)),
            _divider(),
            Expanded(child: _statItem('已掌握', '$mastered', AppColors.green)),
            _divider(),
            Expanded(child: _statItem('掌握率',
                '${(rate * 100).toStringAsFixed(0)}%', AppColors.amber)),
          ],
        ),
      ),
    );
  }

  Widget _statItem(String label, String value, Color color) => Column(
    children: [
      Text(value, style: TextStyle(
          color: color, fontSize: 20, fontWeight: FontWeight.w700)),
      const SizedBox(height: 2),
      Text(label, style: AppText.label),
    ],
  );

  Widget _divider() => Container(
    width: 1, height: 36, color: AppColors.bg3,
    margin: const EdgeInsets.symmetric(horizontal: 4));

  Widget _buildFilterChips() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Wrap(
        spacing: 6,
        children: [
          if (_filterSubject != null)
            _FilterChip(_filterSubject!,
                onRemove: () { setState(() => _filterSubject = null); _load(); }),
          if (_filterGrade != null)
            _FilterChip(_filterGrade!,
                onRemove: () { setState(() => _filterGrade = null); _load(); }),
          if (_filterStatus != null)
            _FilterChip(AppConst.reviewLabels[_filterStatus!] ?? _filterStatus!,
                onRemove: () { setState(() => _filterStatus = null); _load(); }),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    final hasFilter = _filterSubject != null ||
        _filterGrade != null || _filterStatus != null;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(hasFilter ? Icons.filter_list_off : Icons.auto_stories_outlined,
              size: 48, color: AppColors.textMuted),
          const SizedBox(height: 16),
          Text(
            hasFilter ? '当前筛选条件下没有记录' : '还没有错题\n点击下方按钮开始添加',
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: AppColors.textSecondary, fontSize: 14, height: 1.6),
          ),
          if (hasFilter) ...[
            const SizedBox(height: 16),
            TextButton(
              onPressed: () {
                setState(() {
                  _filterSubject = null;
                  _filterGrade = null;
                  _filterStatus = null;
                });
                _load();
              },
              child: const Text('清除筛选'),
            ),
          ],
        ],
      ),
    );
  }

  void _showFilterSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.bg1,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _FilterSheet(
        subject: _filterSubject,
        grade: _filterGrade,
        status: _filterStatus,
        onApply: (s, g, st) {
          setState(() {
            _filterSubject = s;
            _filterGrade = g;
            _filterStatus = st;
          });
          _load();
          Navigator.pop(context);
        },
      ),
    );
  }

  Future<void> _confirmDelete(WrongAnswerRecord r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.bg1,
        title: const Text('删除错题',
            style: TextStyle(color: AppColors.textPrimary)),
        content: const Text('确认删除这道题？无法恢复。',
            style: TextStyle(color: AppColors.textSecondary)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除',
                style: TextStyle(color: AppColors.red)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await DbHelper.instance.delete(r.id);
      _load();
    }
  }
}

// ── 筛选底部弹窗 ──────────────────────────────────────────────────────────────
class _FilterSheet extends StatefulWidget {
  final String? subject, grade, status;
  final void Function(String?, String?, String?) onApply;

  const _FilterSheet({
    this.subject, this.grade, this.status, required this.onApply});

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  String? _sub, _grade, _status;

  @override
  void initState() {
    super.initState();
    _sub = widget.subject;
    _grade = widget.grade;
    _status = widget.status;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('筛选', style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          const Text('科目', style: AppText.label),
          const SizedBox(height: 8),
          _chips(AppConst.subjectList, _sub,
              (v) => setState(() => _sub = _sub == v ? null : v)),
          const SizedBox(height: 14),
          const Text('年级', style: AppText.label),
          const SizedBox(height: 8),
          _chips(AppConst.gradeList, _grade,
              (v) => setState(() => _grade = _grade == v ? null : v)),
          const SizedBox(height: 14),
          const Text('状态', style: AppText.label),
          const SizedBox(height: 8),
          _chips(AppConst.reviewLabels.values.toList(), _status != null
              ? AppConst.reviewLabels[_status!] : null,
              (v) {
                final key = AppConst.reviewLabels.entries
                    .firstWhere((e) => e.value == v).key;
                setState(() => _status = _status == key ? null : key);
              }),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => widget.onApply(_sub, _grade, _status),
              child: const Text('应用筛选'),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _chips(List<String> items, String? selected, void Function(String) onTap) {
    return Wrap(
      spacing: 6, runSpacing: 6,
      children: items.map((item) {
        final active = selected == item;
        return GestureDetector(
          onTap: () => onTap(item),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: active ? AppColors.amber.withOpacity(0.15) : AppColors.bg2,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                  color: active ? AppColors.amber : AppColors.bg3),
            ),
            child: Text(item,
                style: TextStyle(
                    color: active ? AppColors.amber : AppColors.textSecondary,
                    fontSize: 13,
                    fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
          ),
        );
      }).toList(),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final VoidCallback onRemove;
  const _FilterChip(this.label, {required this.onRemove});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: AppColors.amber.withOpacity(0.12),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: AppColors.amber.withOpacity(0.4)),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: const TextStyle(
          color: AppColors.amber, fontSize: 12, fontWeight: FontWeight.w500)),
      const SizedBox(width: 4),
      GestureDetector(
        onTap: onRemove,
        child: const Icon(Icons.close, size: 13, color: AppColors.amber)),
    ]),
  );
}
