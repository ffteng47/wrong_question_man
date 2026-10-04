// lib/screens/paper_capture_screen.dart
// 纸面作业多页选图/拍照 → EXIF 归一 → 上传判题任务
// 上限与服务端 LIMITS.maxPages 对齐（20 页），单张 20MB 由服务端校验
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import '../api/semec_teaching_api.dart';
import '../models/paper_models.dart';
import '../utils/theme.dart';
import 'paper_result_screen.dart';

const int _kMaxPages = 20;

class PaperCaptureScreen extends StatefulWidget {
  final PaperAssignment? assignment;
  const PaperCaptureScreen({super.key, this.assignment});

  @override
  State<PaperCaptureScreen> createState() => _PaperCaptureScreenState();
}

class _PaperCaptureScreenState extends State<PaperCaptureScreen> {
  final _picker = ImagePicker();
  final List<File> _files = [];

  bool _submitting = false;
  double _progress = 0;
  String? _error;

  Future<void> _addImages(List<XFile> picked) async {
    if (picked.isEmpty) return;
    if (_files.length + picked.length > _kMaxPages) {
      setState(() => _error = '最多上传 $_kMaxPages 页');
      return;
    }
    for (final x in picked) {
      final file = File(x.path);
      await _bakeOrientation(file);
      _files.add(file);
    }
    setState(() { _error = null; _progress = 0; });
  }

  Future<void> _pickFromCamera() async {
    final x = await _picker.pickImage(source: ImageSource.camera, imageQuality: 95, maxWidth: 4000);
    if (x != null) await _addImages([x]);
  }

  Future<void> _pickFromGallery() async {
    final xs = await _picker.pickMultiImage(imageQuality: 95, maxWidth: 4000);
    await _addImages(xs);
  }

  /// JPEG/HEIC 按 EXIF 方向烘焙，与错题链路同一处理
  Future<void> _bakeOrientation(File file) async {
    final ext = file.path.toLowerCase();
    if (!(ext.endsWith('.jpg') || ext.endsWith('.jpeg') || ext.endsWith('.heic'))) {
      return;
    }
    try {
      final bytes = await file.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return;
      final oriented = img.bakeOrientation(decoded);
      if (oriented != decoded) {
        await file.writeAsBytes(img.encodeJpg(oriented, quality: 95));
      }
    } catch (e) {
      print('EXIF 校正失败: $e');
    }
  }

  Future<void> _submit() async {
    if (_files.isEmpty) return;
    setState(() { _submitting = true; _error = null; _progress = 0; });
    try {
      final created = await SemecTeachingApi.instance.createPaperUpload(
        _files,
        assignId: widget.assignment?.assignId,
        onProgress: (sent, total) {
          if (total > 0) setState(() => _progress = sent / total);
        },
      );
      if (!mounted) return;
      // 进入任务详情页，返回时通知上层刷新作业列表
      await Navigator.pushReplacement(context,
        MaterialPageRoute(builder: (_) =>
            PaperResultScreen(uploadId: created.uploadId, uploadNo: created.uploadNo)));
    } catch (e) {
      if (mounted) {
        setState(() { _submitting = false; _error = e.toString(); });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.assignment;
    return Scaffold(
      backgroundColor: AppColors.bg0,
      appBar: AppBar(
        title: Text(a == null ? '自由上传' : '提交作业'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (a != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.bg1,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.bg3),
                ),
                child: Text(
                  a.examTitle.isNotEmpty ? a.examTitle : (a.paperTitle ?? ''),
                  style: const TextStyle(
                      color: AppColors.textPrimary, fontSize: 14,
                      fontWeight: FontWeight.w600),
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _submitting ? null : _pickFromCamera,
                    icon: const Icon(Icons.camera_alt_outlined, size: 18),
                    label: const Text('拍照'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _submitting ? null : _pickFromGallery,
                    icon: const Icon(Icons.photo_library_outlined,
                        size: 18, color: AppColors.textSecondary),
                    label: const Text('相册多选',
                        style: TextStyle(color: AppColors.textSecondary)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppColors.bg3),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('共 ${_files.length} 页（上限 $_kMaxPages），按选取顺序作为页序',
                style: const TextStyle(
                    color: AppColors.textMuted, fontSize: 12)),
            const SizedBox(height: 12),
            Expanded(
              child: _files.isEmpty
                  ? const Center(
                      child: Text('请先拍照或从相册选择试卷页面',
                          style: TextStyle(
                              color: AppColors.textMuted, fontSize: 13)),
                    )
                  : GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8),
                      itemCount: _files.length,
                      itemBuilder: (_, i) => Stack(
                        fit: StackFit.expand,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.file(_files[i], fit: BoxFit.cover),
                          ),
                          Positioned(
                            left: 4, top: 4,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.6),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text('${i + 1}',
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 11)),
                            ),
                          ),
                          Positioned(
                            right: 2, top: 2,
                            child: GestureDetector(
                              onTap: _submitting
                                  ? null
                                  : () => setState(() => _files.removeAt(i)),
                              child: Container(
                                padding: const EdgeInsets.all(2),
                                decoration: const BoxDecoration(
                                    color: Colors.black54,
                                    shape: BoxShape.circle),
                                child: const Icon(Icons.close,
                                    size: 14, color: Colors.white),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_error!,
                    style: const TextStyle(color: AppColors.red, fontSize: 12)),
              ),
            if (_submitting) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                  value: _progress > 0 && _progress < 1 ? _progress : null,
                  backgroundColor: AppColors.bg2,
                  color: AppColors.amber,
                  minHeight: 3),
              const SizedBox(height: 6),
              Text(_progress >= 1 ? '服务端处理中…' : '上传中…',
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 12)),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: (_files.isEmpty || _submitting) ? null : _submit,
                icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                label: Text(_submitting ? '提交中…'
                    : '提交判题（${_files.length} 页）'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
