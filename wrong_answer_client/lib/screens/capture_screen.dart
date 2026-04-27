// lib/screens/capture_screen.dart
//
// 拍照/选图 → 上传 → ROI 框选 → 触发语义分析 → 跳转预览
// 支持断点恢复：传入 resumeDraft 可跳过上传直接进入 ROI
//
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import '../api/api_client.dart';
import '../models/wrong_answer_record.dart';
import '../utils/draft_helper.dart';
import '../utils/theme.dart';
import '../widgets/roi_selector.dart';
import 'preview_screen.dart';

enum _Stage { idle, uploading, selectingRoi, extracting, done }

class CaptureScreen extends StatefulWidget {
  final DraftTask? resumeDraft;
  const CaptureScreen({super.key, this.resumeDraft});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  _Stage _stage = _Stage.idle;
  File? _imageFile;
  UploadResponse? _uploadResp;
  String _statusMsg = '';
  double _uploadProgress = 0;
  String? _currentDraftId; // 当前关联的草稿 ID

  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    if (widget.resumeDraft != null) {
      _resumeFromDraft(widget.resumeDraft!);
    }
  }

  // ── 从草稿恢复 ────────────────────────────────────────────────────────────
  void _resumeFromDraft(DraftTask draft) {
    final file = File(draft.localPath);
    if (!file.existsSync()) {
      // 本地图片被系统清理，保留草稿 ID，提示用户重新选图
      _currentDraftId = draft.id;
      _imageFile = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showError('本地图片已被清理，请重新选图');
        }
      });
      return;
    }

    _imageFile = file;
    _uploadResp = UploadResponse(
      imageId: draft.imageId,
      widthPx: draft.widthPx,
      heightPx: draft.heightPx,
      previewBlocks: const [],
    );
    _currentDraftId = draft.id;
    _stage = _Stage.selectingRoi;
  }

  // ── 图片获取 ──────────────────────────────────────────────────────────────
  Future<void> _pickImage(ImageSource source) async {
    final xFile = await _picker.pickImage(
      source: source,
      imageQuality: 95, // 保留高质量供 OCR
      maxWidth: 4000,
    );
    if (xFile == null) return;

    // EXIF 方向校正（仅 JPEG/HEIC，PNG 不支持 EXIF Orientation）
    final originalFile = File(xFile.path);
    final ext = xFile.path.toLowerCase();
    if (ext.endsWith('.jpg') || ext.endsWith('.jpeg') || ext.endsWith('.heic')) {
      try {
        final bytes = await originalFile.readAsBytes();
        final originalImage = img.decodeImage(bytes);
        if (originalImage != null) {
          final orientedImage = img.bakeOrientation(originalImage);
          if (orientedImage != originalImage) {
            await originalFile.writeAsBytes(
              img.encodeJpg(orientedImage, quality: 95),
            );
          }
        }
      } catch (e) {
        print('EXIF 校正失败: $e');
      }
    }

    // 若之前有遗留草稿（如图片被清理后重新选图），先删除旧草稿
    if (_currentDraftId != null) {
      await DraftHelper.instance.delete(_currentDraftId!);
      _currentDraftId = null;
    }

    setState(() {
      _imageFile = originalFile;
      _uploadResp = null;
      _stage = _Stage.idle;
    });
    await _uploadImage();
  }

  // ── Stage 1: 上传 ─────────────────────────────────────────────────────────
  Future<void> _uploadImage() async {
    if (_imageFile == null) return;
    setState(() {
      _stage = _Stage.uploading;
      _statusMsg = '上传图片…';
      _uploadProgress = 0;
    });

    try {
      final resp = await ApiClient.instance.uploadImage(
        _imageFile!,
        onProgress: (sent, total) {
          if (total > 0) setState(() => _uploadProgress = sent / total);
        },
      );

      // 上传成功，立即持久化草稿
      final draft = DraftTask(
        id: const Uuid().v4(),
        imageId: resp.imageId,
        localPath: _imageFile!.path,
        imageSource: 'camera',
        widthPx: resp.widthPx,
        heightPx: resp.heightPx,
        status: DraftStatus.uploadOk,
        createdAt: DateTime.now().toUtc().toIso8601String(),
      );
      await DraftHelper.instance.upsert(draft);
      _currentDraftId = draft.id;

      setState(() {
        _uploadResp = resp;
        _stage = _Stage.selectingRoi;
        _statusMsg = '';
      });
    } catch (e) {
      _showError('上传失败: $e');
      setState(() => _stage = _Stage.idle);
    }
  }

  // ── Stage 2: ROI 确认后提取 ───────────────────────────────────────────────
  Future<void> _onRoiConfirmed(List<double> roiBbox) async {
    if (_uploadResp == null) return;
    setState(() {
      _stage = _Stage.extracting;
      _statusMsg = 'OCR + 语义分析中…';
    });

    try {
      final record = await ApiClient.instance.extract(
        imageId: _uploadResp!.imageId,
        roiBbox: roiBbox,
        onStageChange: (msg) => setState(() => _statusMsg = msg),
      );
      if (!mounted) return;

      // 提取成功，清理草稿
      if (_currentDraftId != null) {
        await DraftHelper.instance.delete(_currentDraftId!);
        _currentDraftId = null;
      }

      // 跳转到预览/编辑页
      final saved = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => PreviewScreen(record: record)),
      );
      if (saved == true) {
        // 返回首页并刷新
        if (mounted) Navigator.pop(context, true);
      } else {
        setState(() {
          _stage = _Stage.selectingRoi;
          _statusMsg = '';
        });
      }
    } catch (e) {
      _showError('分析失败: $e');

      // 提取失败，更新草稿状态以便后续重试
      if (_currentDraftId != null) {
        await DraftHelper.instance.updateStatus(
          _currentDraftId!,
          DraftStatus.extractFailed,
          errorMsg: e.toString(),
        );
      }

      setState(() {
        _stage = _Stage.selectingRoi;
        _statusMsg = '';
      });
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: AppColors.red),
    );
  }

  // ── UI ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg0,
      appBar: AppBar(
        title: const Text('添加错题'),
        actions: [
          if (_stage == _Stage.selectingRoi)
            IconButton(
              icon: const Icon(Icons.photo_library_outlined),
              tooltip: '重新选图',
              onPressed: () => _pickImage(ImageSource.gallery),
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    switch (_stage) {
      case _Stage.idle:
        return _buildIdle();
      case _Stage.uploading:
        return _buildLoading('上传图片…', progress: _uploadProgress);
      case _Stage.selectingRoi:
        return RoiSelector(
          imageFile: _imageFile!,
          imageWidthPx: _uploadResp!.widthPx,
          imageHeightPx: _uploadResp!.heightPx,
          onConfirm: _onRoiConfirmed,
        );
      case _Stage.extracting:
        return _buildLoading(_statusMsg);
      case _Stage.done:
        return const SizedBox();
    }
  }

  Widget _buildIdle() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 图标
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: AppColors.bg1,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: AppColors.bg3),
              ),
              child: const Icon(
                Icons.document_scanner_outlined,
                size: 44,
                color: AppColors.amber,
              ),
            ),
            const SizedBox(height: 28),
            const Text('添加错题',
                style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            const Text('拍照或从相册选取试卷图片',
                style: TextStyle(
                    color: AppColors.textSecondary, fontSize: 14)),
            const SizedBox(height: 36),
            // 拍照
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => _pickImage(ImageSource.camera),
                icon: const Icon(Icons.camera_alt_outlined),
                label: const Text('拍照'),
              ),
            ),
            const SizedBox(height: 12),
            // 相册
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _pickImage(ImageSource.gallery),
                icon: const Icon(Icons.photo_library_outlined,
                    color: AppColors.textSecondary),
                label: const Text('从相册选取',
                    style: TextStyle(color: AppColors.textSecondary)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: AppColors.bg3),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 24, vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
            // 如果已有图片但未上传（e.g. 出错后重试）
            if (_imageFile != null) ...[
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: _uploadImage,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重新上传'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLoading(String msg, {double? progress}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (progress != null && progress > 0 && progress < 1)
              Column(
                children: [
                  LinearProgressIndicator(
                    value: progress,
                    backgroundColor: AppColors.bg2,
                    color: AppColors.amber,
                    minHeight: 3,
                    borderRadius: BorderRadius.circular(2),
                  ),
                  const SizedBox(height: 16),
                ],
              )
            else
              const Padding(
                padding: EdgeInsets.only(bottom: 20),
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(
                    color: AppColors.amber,
                    strokeWidth: 2.5,
                  ),
                ),
              ),
            Text(msg,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 14)),
            const SizedBox(height: 8),
            const Text('AI 推理中，请耐心等待…',
                style: TextStyle(
                    color: AppColors.textMuted, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
