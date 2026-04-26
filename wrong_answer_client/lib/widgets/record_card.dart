// lib/widgets/record_card.dart
import 'package:flutter/material.dart';
import '../models/wrong_answer_record.dart';
import '../utils/theme.dart';
import 'math_markdown.dart';

class RecordCard extends StatelessWidget {
  final WrongAnswerRecord record;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  final bool isSelectable;
  final bool isSelected;
  final ValueChanged<bool>? onSelectChanged;

  const RecordCard({
    super.key,
    required this.record,
    this.onTap,
    this.onDelete,
    this.isSelectable = false,
    this.isSelected = false,
    this.onSelectChanged,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isSelectable && onSelectChanged != null
          ? () => onSelectChanged!(!isSelected)
          : onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.bg1.withOpacity(0.8) : AppColors.bg1,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? AppColors.amber : AppColors.bg3,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isSelectable)
              Padding(
                padding: const EdgeInsets.only(left: 8, top: 12),
                child: Checkbox(
                  value: isSelected,
                  onChanged: (v) => onSelectChanged?.call(v ?? false),
                  activeColor: AppColors.amber,
                ),
              ),
            Expanded(
              child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 顶部元数据栏 ───────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
              child: Row(
                children: [
                  // 科目标签
                  _SubjectBadge(record.subject),
                  const SizedBox(width: 6),
                  // 年级
                  Text(record.grade,
                      style: AppText.label.copyWith(color: AppColors.textMuted)),
                  const SizedBox(width: 6),
                  // 题型
                  if (record.type != '未知') ...[
                    Text('·', style: AppText.label.copyWith(color: AppColors.textMuted)),
                    const SizedBox(width: 6),
                    Text(record.type, style: AppText.label.copyWith(color: AppColors.textMuted)),
                  ],
                  const Spacer(),
                  // 难度
                  _DifficultyDots(record.difficulty),
                  const SizedBox(width: 8),
                  // 复习状态
                  _StatusDot(record.reviewStatus),
                ],
              ),
            ),

            // ── 题目预览（最多 3 行）─────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              child: _ProblemPreview(problem: record.problem),
            ),

            // ── 知识点 Chips ──────────────────────────────────────────────
            if (record.knowledgePoints.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: record.knowledgePoints.take(3).map((kp) =>
                    _MiniChip(kp)
                  ).toList(),
                ),
              ),

            // ── 底部时间 + 操作 ──────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
              child: Row(
                children: [
                  Icon(Icons.access_time,
                      size: 11, color: AppColors.textMuted),
                  const SizedBox(width: 4),
                  Text(
                    _formatDate(record.createdAt),
                    style: AppText.mono.copyWith(fontSize: 11),
                  ),
                  if (record.assignedToStudentName != null) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.green.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '已分配给 ${record.assignedToStudentName}',
                        style: TextStyle(
                          color: AppColors.green,
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (onDelete != null)
                    IconButton(
                      icon: const Icon(Icons.delete_outline,
                          size: 16, color: AppColors.textMuted),
                      onPressed: onDelete,
                      splashRadius: 16,
                      tooltip: '删除',
                    ),
                  const Icon(Icons.chevron_right,
                      size: 18, color: AppColors.textMuted),
                ],
              ),
            ),
          ],
        ),
      ),
    ],
  ),
),
);
  }

  String _formatDate(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
    } catch (_) {
      return iso.substring(0, min(10, iso.length));
    }
  }

  int min(int a, int b) => a < b ? a : b;
}

// ── 子组件 ────────────────────────────────────────────────────────────────────

class _SubjectBadge extends StatelessWidget {
  final String subject;
  const _SubjectBadge(this.subject);

  @override
  Widget build(BuildContext context) {
    final color = _subjectColor(subject);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(
        subject,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  Color _subjectColor(String s) => switch (s) {
    '数学' => AppColors.blue,
    '物理' => AppColors.purple,
    '化学' => AppColors.green,
    '语文' => AppColors.amber,
    '英语' => const Color(0xFF79C0FF),
    '生物' => const Color(0xFF56D364),
    '历史' => const Color(0xFFFF7B72),
    '地理' => const Color(0xFF8BDB80),
    _     => AppColors.textSecondary,
  };
}

class _DifficultyDots extends StatelessWidget {
  final int difficulty;
  const _DifficultyDots(this.difficulty);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) => Padding(
        padding: const EdgeInsets.only(left: 2),
        child: Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: i < difficulty
                ? AppColors.difficulty(difficulty)
                : AppColors.bg3,
          ),
        ),
      )),
    );
  }
}

class _StatusDot extends StatelessWidget {
  final String status;
  const _StatusDot(this.status);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.reviewStatus(status),
      ),
    );
  }
}

class _MiniChip extends StatelessWidget {
  final String label;
  const _MiniChip(this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.bg2,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.bg3),
      ),
      child: Text(label,
          style: const TextStyle(
              color: AppColors.textMuted, fontSize: 11)),
    );
  }
}

class _ProblemPreview extends StatelessWidget {
  final String problem;
  const _ProblemPreview({required this.problem});

  @override
  Widget build(BuildContext context) {
    // 截取前 120 字符避免卡片过高
    final preview = problem.length > 120
        ? '${problem.substring(0, 120)}…'
        : problem;
    return MathMarkdown(
      data: preview,
      fontSize: 14,
    );
  }
}
