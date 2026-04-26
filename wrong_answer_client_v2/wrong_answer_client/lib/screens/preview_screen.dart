// lib/screens/preview_screen.dart
//
// 显示 AI 提取结果，允许用户编辑后保存
//
import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../models/wrong_answer_record.dart';
import '../utils/db_helper.dart';
import '../utils/theme.dart';
import '../widgets/math_markdown.dart';

class PreviewScreen extends StatefulWidget {
  final WrongAnswerRecord record;

  const PreviewScreen({super.key, required this.record});

  @override
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen>
    with SingleTickerProviderStateMixin {
  late WrongAnswerRecord _record;
  late TabController _tabs;
  bool _saving = false;
  bool _showAnswer = false;

  @override
  void initState() {
    super.initState();
    _record = widget.record;
    _tabs = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      // 同步到服务端
      await ApiClient.instance.saveRecord(_record);
      // 保存到本地 SQLite
      await DbHelper.instance.upsert(_record);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✓ 已保存')));
        Navigator.pop(context, true);  // 通知 CaptureScreen 已保存
      }
    } catch (e) {
      // 服务端失败时仍尝试本地保存
      try { await DbHelper.instance.upsert(_record); } catch (_) {}
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('服务端同步失败，已本地保存: $e'),
            backgroundColor: AppColors.amber,
          ),
        );
        Navigator.pop(context, true);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg0,
      appBar: AppBar(
        title: Text('${_record.subject} · ${_record.type}'),
        bottom: TabBar(
          controller: _tabs,
          labelColor: AppColors.amber,
          unselectedLabelColor: AppColors.textSecondary,
          indicatorColor: AppColors.amber,
          indicatorSize: TabBarIndicatorSize.tab,
          tabs: const [
            Tab(text: '题目'),
            Tab(text: '分析'),
            Tab(text: '信息'),
          ],
        ),
        actions: [
          _saving
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.amber),
                  ),
                )
              : TextButton(
                  onPressed: _save,
                  child: const Text('保存',
                      style: TextStyle(
                          color: AppColors.amber, fontWeight: FontWeight.w600)),
                ),
        ],
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _ProblemTab(record: _record, showAnswer: _showAnswer,
              onToggleAnswer: () => setState(() => _showAnswer = !_showAnswer)),
          _AnalysisTab(record: _record),
          _InfoTab(
            record: _record,
            onChanged: (r) => setState(() => _record = r),
          ),
        ],
      ),
    );
  }
}

// ── Tab 1: 题目 + 答案 + 解析 ───────────────────────────────────────────────

class _ProblemTab extends StatelessWidget {
  final WrongAnswerRecord record;
  final bool showAnswer;
  final VoidCallback onToggleAnswer;

  const _ProblemTab({
    required this.record,
    required this.showAnswer,
    required this.onToggleAnswer,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SectionLabel('题目'),
        const SizedBox(height: 8),
        _Card(child: MathMarkdown(data: record.problem, fontSize: 15, selectable: true)),

        const SizedBox(height: 16),
        Row(
          children: [
            const _SectionLabel('答案'),
            const Spacer(),
            TextButton.icon(
              onPressed: onToggleAnswer,
              icon: Icon(showAnswer ? Icons.visibility_off : Icons.visibility,
                  size: 15),
              label: Text(showAnswer ? '隐藏' : '显示',
                  style: const TextStyle(fontSize: 13)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        AnimatedCrossFade(
          firstChild: Container(
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.bg2,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Center(
              child: Text('点击「显示」查看答案',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
            ),
          ),
          secondChild: _Card(
            child: MathMarkdown(
                data: record.answer.isEmpty ? '（未识别）' : record.answer,
                fontSize: 15,
                selectable: true),
          ),
          crossFadeState: showAnswer
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
        ),

        if (record.solution.isNotEmpty) ...[
          const SizedBox(height: 16),
          const _SectionLabel('解题过程'),
          const SizedBox(height: 8),
          _Card(child: MathMarkdown(
              data: record.solution, fontSize: 14, selectable: true)),
        ],
      ],
    );
  }
}

// ── Tab 2: 错因分析 ──────────────────────────────────────────────────────────

class _AnalysisTab extends StatelessWidget {
  final WrongAnswerRecord record;
  const _AnalysisTab({required this.record});

  @override
  Widget build(BuildContext context) {
    final ea = record.errorAnalysis;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (ea.studentAnswer.isNotEmpty) ...[
          const _SectionLabel('学生答案'),
          const SizedBox(height: 8),
          _Card(
            color: AppColors.red.withOpacity(0.08),
            borderColor: AppColors.red.withOpacity(0.3),
            child: MathMarkdown(data: ea.studentAnswer, fontSize: 14),
          ),
          const SizedBox(height: 16),
        ],

        const _SectionLabel('错误类型'),
        const SizedBox(height: 8),
        _Card(
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.amber.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppColors.amber.withOpacity(0.4)),
                ),
                child: Text(ea.errorCategory,
                    style: const TextStyle(
                        color: AppColors.amber,
                        fontWeight: FontWeight.w600,
                        fontSize: 13)),
              ),
            ],
          ),
        ),

        if (ea.errorDesc.isNotEmpty) ...[
          const SizedBox(height: 16),
          const _SectionLabel('错误原因'),
          const SizedBox(height: 8),
          _Card(child: Text(ea.errorDesc,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 14, height: 1.6))),
        ],

        if (ea.preventionTip.isNotEmpty) ...[
          const SizedBox(height: 16),
          const _SectionLabel('避免方法'),
          const SizedBox(height: 8),
          _Card(
            color: AppColors.green.withOpacity(0.06),
            borderColor: AppColors.green.withOpacity(0.3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Icon(Icons.lightbulb_outline,
                      size: 15, color: AppColors.green),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(ea.preventionTip,
                      style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 14,
                          height: 1.6)),
                ),
              ],
            ),
          ),
        ],

        if (record.keyPoints.isNotEmpty) ...[
          const SizedBox(height: 16),
          const _SectionLabel('考察要点'),
          const SizedBox(height: 8),
          ...record.keyPoints.map((kp) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _Card(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Icon(Icons.radio_button_checked,
                        size: 10, color: AppColors.amber),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: MathMarkdown(data: kp, fontSize: 13)),
                ],
              ),
            ),
          )),
        ],
      ],
    );
  }
}

// ── Tab 3: 元数据编辑 ────────────────────────────────────────────────────────

class _InfoTab extends StatelessWidget {
  final WrongAnswerRecord record;
  final void Function(WrongAnswerRecord) onChanged;

  const _InfoTab({required this.record, required this.onChanged});

  WrongAnswerRecord _copy() => WrongAnswerRecord.fromJson(record.toJson());

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 科目
        const _SectionLabel('科目'),
        const SizedBox(height: 8),
        _DropdownField(
          value: record.subject,
          items: AppConst.subjectList,
          onChanged: (v) {
            if (v == null) return;
            final r = _copy(); r.subject = v; onChanged(r);
          },
        ),

        const SizedBox(height: 16),
        // 年级
        const _SectionLabel('年级'),
        const SizedBox(height: 8),
        _DropdownField(
          value: record.grade,
          items: AppConst.gradeList,
          onChanged: (v) {
            if (v == null) return;
            final r = _copy(); r.grade = v; onChanged(r);
          },
        ),

        const SizedBox(height: 16),
        // 难度
        const _SectionLabel('难度'),
        const SizedBox(height: 8),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(AppConst.difficultyLabels[record.difficulty],
                  style: TextStyle(
                      color: AppColors.difficulty(record.difficulty),
                      fontWeight: FontWeight.w600)),
              Slider(
                value: record.difficulty.toDouble(),
                min: 1, max: 5, divisions: 4,
                activeColor: AppColors.difficulty(record.difficulty),
                inactiveColor: AppColors.bg3,
                onChanged: (v) {
                  final r = _copy(); r.difficulty = v.round(); onChanged(r);
                },
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),
        // 复习状态
        const _SectionLabel('复习状态'),
        const SizedBox(height: 8),
        _Card(
          child: Row(
            children: AppConst.reviewLabels.entries.map((e) =>
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    final r = _copy(); r.reviewStatus = e.key; onChanged(r);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: record.reviewStatus == e.key
                          ? AppColors.reviewStatus(e.key).withOpacity(0.2)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: record.reviewStatus == e.key
                            ? AppColors.reviewStatus(e.key)
                            : Colors.transparent,
                      ),
                    ),
                    child: Text(
                      e.value,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: record.reviewStatus == e.key
                            ? AppColors.reviewStatus(e.key)
                            : AppColors.textMuted,
                        fontSize: 12,
                        fontWeight: record.reviewStatus == e.key
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                ),
              )
            ).toList(),
          ),
        ),

        const SizedBox(height: 16),
        // 知识点
        if (record.knowledgePoints.isNotEmpty) ...[
          const _SectionLabel('知识点'),
          const SizedBox(height: 8),
          _Card(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: record.knowledgePoints.map((kp) =>
                Chip(
                  label: Text(kp),
                  deleteIcon: const Icon(Icons.close, size: 14),
                  onDeleted: () {
                    final r = _copy();
                    r.knowledgePoints = [...r.knowledgePoints]..remove(kp);
                    onChanged(r);
                  },
                )
              ).toList(),
            ),
          ),
        ],

        const SizedBox(height: 16),
        // 标签
        const _SectionLabel('标签'),
        const SizedBox(height: 8),
        _Card(
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ...record.tags.map((t) => Chip(
                label: Text(t),
                deleteIcon: const Icon(Icons.close, size: 14),
                onDeleted: () {
                  final r = _copy();
                  r.tags = [...r.tags]..remove(t);
                  onChanged(r);
                },
              )),
            ],
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }
}

// ── 通用子组件 ────────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: AppText.label,
  );
}

class _Card extends StatelessWidget {
  final Widget child;
  final Color? color;
  final Color? borderColor;

  const _Card({required this.child, this.color, this.borderColor});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: color ?? AppColors.bg1,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: borderColor ?? AppColors.bg3),
    ),
    child: child,
  );
}

class _DropdownField extends StatelessWidget {
  final String value;
  final List<String> items;
  final void Function(String?) onChanged;

  const _DropdownField({
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: BoxDecoration(
      color: AppColors.bg2,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: AppColors.bg3),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: items.contains(value) ? value : null,
        hint: Text(value, style: const TextStyle(color: AppColors.textSecondary)),
        items: items.map((s) => DropdownMenuItem(
          value: s,
          child: Text(s, style: const TextStyle(color: AppColors.textPrimary)),
        )).toList(),
        onChanged: onChanged,
        dropdownColor: AppColors.bg2,
        style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
        icon: const Icon(Icons.expand_more, color: AppColors.textSecondary),
        isExpanded: true,
      ),
    ),
  );
}
