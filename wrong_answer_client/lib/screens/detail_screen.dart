// lib/screens/detail_screen.dart
//
// 已保存记录的详情页（只读，可修改复习状态）
//
import 'package:flutter/material.dart';
import '../models/wrong_answer_record.dart';
import '../utils/db_helper.dart';
import '../utils/theme.dart';
import '../widgets/math_markdown.dart';

class DetailScreen extends StatefulWidget {
  final WrongAnswerRecord record;
  const DetailScreen({super.key, required this.record});

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen>
    with SingleTickerProviderStateMixin {
  late WrongAnswerRecord _record;
  late TabController _tabs;
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

  Future<void> _updateStatus(String status) async {
    await DbHelper.instance.updateReviewStatus(_record.id, status);
    setState(() => _record.reviewStatus = status);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已标记为「${AppConst.reviewLabels[status]}」')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg0,
      appBar: AppBar(
        title: Text('${_record.subject}  ${_record.grade}'),
        bottom: TabBar(
          controller: _tabs,
          labelColor: AppColors.amber,
          unselectedLabelColor: AppColors.textSecondary,
          indicatorColor: AppColors.amber,
          tabs: const [
            Tab(text: '题目'),
            Tab(text: '分析'),
            Tab(text: '元信息'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _buildProblemTab(),
          _buildAnalysisTab(),
          _buildMetaTab(),
        ],
      ),
      bottomNavigationBar: _buildStatusBar(),
    );
  }

  Widget _buildProblemTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _label('题目'),
        const SizedBox(height: 8),
        _card(child: MathMarkdown(
            data: _record.problem, fontSize: 15, selectable: true)),

        const SizedBox(height: 16),
        Row(children: [
          _label('答案'),
          const Spacer(),
          TextButton.icon(
            onPressed: () => setState(() => _showAnswer = !_showAnswer),
            icon: Icon(_showAnswer ? Icons.visibility_off : Icons.visibility,
                size: 15),
            label: Text(_showAnswer ? '隐藏' : '显示',
                style: const TextStyle(fontSize: 13)),
          ),
        ]),
        const SizedBox(height: 8),
        AnimatedCrossFade(
          firstChild: Container(
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.bg2,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Center(child: Text('点击「显示」查看答案',
                style: TextStyle(color: AppColors.textMuted, fontSize: 13))),
          ),
          secondChild: _card(child: MathMarkdown(
              data: _record.answer.isEmpty ? '（未识别）' : _record.answer,
              fontSize: 15,
              selectable: true)),
          crossFadeState: _showAnswer
              ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
        ),

        if (_record.solution.isNotEmpty) ...[
          const SizedBox(height: 16),
          _label('解题过程'),
          const SizedBox(height: 8),
          _card(child: MathMarkdown(
              data: _record.solution, fontSize: 14, selectable: true)),
        ],
      ],
    );
  }

  Widget _buildAnalysisTab() {
    final ea = _record.errorAnalysis;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (ea.studentAnswer.isNotEmpty) ...[
          _label('学生答案'),
          const SizedBox(height: 8),
          _card(
            color: AppColors.red.withOpacity(0.08),
            border: AppColors.red.withOpacity(0.3),
            child: MathMarkdown(data: ea.studentAnswer, fontSize: 14),
          ),
          const SizedBox(height: 16),
        ],
        _label('错误类型'),
        const SizedBox(height: 8),
        _card(child: Row(children: [
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
        ])),
        if (ea.errorDesc.isNotEmpty) ...[
          const SizedBox(height: 16),
          _label('错误原因'),
          const SizedBox(height: 8),
          _card(child: Text(ea.errorDesc,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 14, height: 1.6))),
        ],
        if (ea.preventionTip.isNotEmpty) ...[
          const SizedBox(height: 16),
          _label('避免方法'),
          const SizedBox(height: 8),
          _card(
            color: AppColors.green.withOpacity(0.06),
            border: AppColors.green.withOpacity(0.3),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Padding(padding: EdgeInsets.only(top: 2),
                  child: Icon(Icons.lightbulb_outline,
                      size: 15, color: AppColors.green)),
              const SizedBox(width: 8),
              Expanded(child: Text(ea.preventionTip,
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 14, height: 1.6))),
            ]),
          ),
        ],
        if (_record.keyPoints.isNotEmpty) ...[
          const SizedBox(height: 16),
          _label('考察要点'),
          const SizedBox(height: 8),
          ..._record.keyPoints.map((kp) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _card(child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Padding(padding: EdgeInsets.only(top: 4),
                  child: Icon(Icons.radio_button_checked,
                      size: 10, color: AppColors.amber)),
              const SizedBox(width: 8),
              Expanded(child: MathMarkdown(data: kp, fontSize: 13)),
            ])),
          )),
        ],
      ],
    );
  }

  Widget _buildMetaTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _metaRow('题型', _record.type),
        _metaRow('科目', _record.subject),
        _metaRow('年级', _record.grade),
        _metaRow('难度', AppConst.difficultyLabels[_record.difficulty]),
        _metaRow('得分', _record.realScore.toString()),
        const Divider(height: 24),
        if (_record.chapters.isNotEmpty)
          _metaRow('章节', _record.chapters.join('、')),
        if (_record.knowledgePoints.isNotEmpty) ...[
          const SizedBox(height: 12),
          _label('知识点'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6, runSpacing: 6,
            children: _record.knowledgePoints
                .map((kp) => Chip(label: Text(kp))).toList(),
          ),
        ],
        if (_record.tags.isNotEmpty) ...[
          const SizedBox(height: 16),
          _label('标签'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6, runSpacing: 6,
            children: _record.tags
                .map((t) => Chip(label: Text(t))).toList(),
          ),
        ],
        const Divider(height: 24),
        _metaRow('录入时间', _formatDate(_record.createdAt)),
      ],
    );
  }

  Widget _buildStatusBar() {
    return Container(
      color: AppColors.bg1,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Row(
        children: AppConst.reviewLabels.entries.map((e) {
          final selected = _record.reviewStatus == e.key;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: GestureDetector(
                onTap: () => _updateStatus(e.key),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: selected
                        ? AppColors.reviewStatus(e.key).withOpacity(0.2)
                        : AppColors.bg2,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: selected
                          ? AppColors.reviewStatus(e.key)
                          : AppColors.bg3,
                    ),
                  ),
                  child: Text(
                    e.value,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: selected
                          ? AppColors.reviewStatus(e.key)
                          : AppColors.textMuted,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _label(String t) => Text(t.toUpperCase(), style: AppText.label);

  Widget _card({required Widget child, Color? color, Color? border}) =>
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color ?? AppColors.bg1,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: border ?? AppColors.bg3),
        ),
        child: child,
      );

  Widget _metaRow(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(children: [
      SizedBox(width: 80,
          child: Text(k, style: AppText.label)),
      Expanded(child: Text(v,
          style: const TextStyle(
              color: AppColors.textPrimary, fontSize: 14))),
    ]),
  );

  String _formatDate(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.year}/${dt.month}/${dt.day} '
          '${dt.hour.toString().padLeft(2,'0')}:'
          '${dt.minute.toString().padLeft(2,'0')}';
    } catch (_) { return iso; }
  }
}
