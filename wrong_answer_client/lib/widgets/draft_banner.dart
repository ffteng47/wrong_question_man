// lib/widgets/draft_banner.dart
//
// 首页顶部的草稿横幅：提示用户有未完成的提取任务
//
import 'dart:io';
import 'package:flutter/material.dart';
import '../utils/draft_helper.dart';
import '../utils/theme.dart';

class DraftBanner extends StatelessWidget {
  final DraftTask draft;
  final VoidCallback onResume;
  final VoidCallback onDiscard;

  const DraftBanner({
    super.key,
    required this.draft,
    required this.onResume,
    required this.onDiscard,
  });

  String get _statusLabel {
    switch (draft.status) {
      case DraftStatus.uploadOk:
        return '等待框选错题区域';
      case DraftStatus.extractFailed:
        return '分析失败，可重试';
      default:
        return '待处理';
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasLocalImage = File(draft.localPath).existsSync();

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.amber.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.amber.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          // 缩略图
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: hasLocalImage
                ? Image.file(
                    File(draft.localPath),
                    width: 56,
                    height: 56,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _placeholderImage(),
                  )
                : _placeholderImage(),
          ),
          const SizedBox(width: 12),
          // 文字信息
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '未完成的错题',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _statusLabel,
                  style: TextStyle(
                    color: draft.status == DraftStatus.extractFailed
                        ? AppColors.red
                        : AppColors.amber,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (draft.errorMsg != null && draft.errorMsg!.isNotEmpty)
                  Text(
                    draft.errorMsg!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
          // 操作按钮
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: onDiscard,
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.textMuted,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('放弃', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 4),
              ElevatedButton(
                onPressed: onResume,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.amber,
                  foregroundColor: AppColors.bg0,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: const Text('继续'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _placeholderImage() => Container(
        width: 56,
        height: 56,
        color: AppColors.bg2,
        child: const Icon(
          Icons.broken_image_outlined,
          color: AppColors.textMuted,
          size: 24,
        ),
      );
}
