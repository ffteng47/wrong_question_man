// lib/widgets/draft_banner.dart
//
// 首页顶部的草稿任务横幅：有待处理任务时显示，点击进入断点恢复
//
import 'dart:io';
import 'package:flutter/material.dart';
import '../utils/draft_helper.dart';
import '../utils/theme.dart';

class DraftBanner extends StatelessWidget {
  final List<DraftTask> drafts;
  final void Function(DraftTask) onResume;
  final void Function(DraftTask) onDiscard;

  const DraftBanner({
    super.key,
    required this.drafts,
    required this.onResume,
    required this.onDiscard,
  });

  @override
  Widget build(BuildContext context) {
    if (drafts.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      decoration: BoxDecoration(
        color: AppColors.amber.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.amber.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 标题栏 ──────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              children: [
                const Icon(Icons.pending_actions,
                    size: 15, color: AppColors.amber),
                const SizedBox(width: 7),
                Text(
                  '${drafts.length} 张图片待处理',
                  style: const TextStyle(
                    color: AppColors.amber,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                const Text(
                  '图片已上传，点击继续框选',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 11),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.bg3),
          // ── 草稿列表 ────────────────────────────────────────────────────
          ...drafts.map((draft) => _DraftItem(
                draft: draft,
                onResume: () => onResume(draft),
                onDiscard: () => onDiscard(draft),
              )),
        ],
      ),
    );
  }
}

class _DraftItem extends StatelessWidget {
  final DraftTask draft;
  final VoidCallback onResume;
  final VoidCallback onDiscard;

  const _DraftItem({
    required this.draft,
    required this.onResume,
    required this.onDiscard,
  });

  @override
  Widget build(BuildContext context) {
    final imageExists = File(draft.localPath).existsSync();
    final isError = draft.status == DraftStatus.extractFailed;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          // 缩略图
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: imageExists
                ? Image.file(
                    File(draft.localPath),
                    width: 48,
                    height: 48,
                    fit: BoxFit.cover,
                  )
                : Container(
                    width: 48,
                    height: 48,
                    color: AppColors.bg2,
                    child: const Icon(Icons.image_not_supported_outlined,
                        size: 20, color: AppColors.textMuted),
                  ),
          ),
          const SizedBox(width: 12),

          // 状态信息
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: isError
                            ? AppColors.red.withOpacity(0.15)
                            : AppColors.amber.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        isError ? '分析失败' : '等待框选',
                        style: TextStyle(
                          color:
                              isError ? AppColors.red : AppColors.amber,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _formatTime(draft.createdAt),
                      style: const TextStyle(
                          color: AppColors.textMuted, fontSize: 11),
                    ),
                  ],
                ),
                if (isError && draft.errorMsg != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    draft.errorMsg!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11,
                        fontFamily: 'monospace'),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),

          // 操作按钮
          TextButton(
            onPressed: onResume,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.amber,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('继续', style: TextStyle(fontSize: 13)),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 15, color: AppColors.textMuted),
            onPressed: onDiscard,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(),
            tooltip: '放弃',
          ),
        ],
      ),
    );
  }

  String _formatTime(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.month}/${dt.day} '
          '${dt.hour.toString().padLeft(2, '0')}:'
          '${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return '';
    }
  }
}
