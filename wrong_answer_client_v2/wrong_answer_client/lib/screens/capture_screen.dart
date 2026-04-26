// lib/screens/capture_screen.dart  （替换原文件）
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import '../api/api_client.dart';
import '../models/wrong_answer_record.dart';
import '../utils/draft_helper.dart';
import '../utils/theme.dart';
import '../widgets/roi_selector.dart';
import 'preview_screen.dart';

enum _Stage { idle, uploading, selectingRoi, extracting }

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
  DraftTask? _currentDraft;
  String _statusMsg = '';
  double _uploadProgress = 0;

  final _picker = ImagePicker();
  final _uuid = const Uuid();

  @override
  void initState() {
    super.initState();
    if (widget.resumeDraft != null) {
      _resumeFromDraft(widget.resumeDraft!);
    }
  }

  Future<void> _resumeFromDraft(DraftTask draft) async {
    _currentDraft = draft;
    _imageFile = File(draft.localPath);
    _uploadResp = UploadResponse(
      imageId: draft.imageId,
      widthPx: draft.widthPx,
      heightPx: draft.heightPx,
      previewBlocks: const [],
    );
    await DraftHelper.instance.updateStatus(draft.id, DraftStatus.uploadOk);
    if (mounted) setState(() => _stage = _Stage.selectingRoi);
  }

  Future<void> _pickImage(ImageSource source) async {
    final xFile = await _picker.pickImage(source: source, imageQuality: 95, maxWidth: 4000);
    if (xFile == null) return;
    setState(() { _imageFile = File(xFile.path); _uploadResp = null; _currentDraft = null; _stage = _Stage.idle; });
    await _uploadImage();
  }

  Future<void> _uploadImage() async {
    if (_imageFile == null) return;
    setState(() { _stage = _Stage.uploading; _statusMsg = '上传图片…'; _uploadProgress = 0; });
    try {
      final resp = await ApiClient.instance.uploadImage(_imageFile!,
          onProgress: (sent, total) { if (total > 0) setState(() => _uploadProgress = sent / total); });

      // ★ 上传成功立即写草稿
      final draft = DraftTask(
        id: _uuid.v4(), imageId: resp.imageId, localPath: _imageFile!.path,
        imageSource: 'camera', widthPx: resp.widthPx, heightPx: resp.heightPx,
        status: DraftStatus.uploadOk, createdAt: DateTime.now().toUtc().toIso8601String(),
      );
      await DraftHelper.instance.upsert(draft);

      setState(() { _uploadResp = resp; _currentDraft = draft; _stage = _Stage.selectingRoi; _statusMsg = ''; });
    } catch (e) {
      _showError('上传失败: $e');
      setState(() => _stage = _Stage.idle);
    }
  }

  Future<void> _onRoiConfirmed(List<double> roiBbox) async {
    if (_uploadResp == null) return;
    setState(() { _stage = _Stage.extracting; _statusMsg = 'OCR + 语义分析中…'; });
    try {
      final record = await ApiClient.instance.extract(
        imageId: _uploadResp!.imageId, roiBbox: roiBbox,
        onStageChange: (msg) => setState(() => _statusMsg = msg),
      );

      // ★ extract 成功：删除草稿
      if (_currentDraft != null) await DraftHelper.instance.delete(_currentDraft!.id);

      if (!mounted) return;
      final saved = await Navigator.push<bool>(context,
          MaterialPageRoute(builder: (_) => PreviewScreen(record: record)));
      if (saved == true && mounted) {
        Navigator.pop(context, true);
      } else {
        setState(() { _stage = _Stage.selectingRoi; _statusMsg = ''; });
      }
    } catch (e) {
      // ★ extract 失败：更新草稿为 extractFailed，下次可断点恢复
      if (_currentDraft != null) {
        await DraftHelper.instance.updateStatus(_currentDraft!.id,
            DraftStatus.extractFailed, errorMsg: e.toString());
      }
      _showError('分析失败: $e');
      setState(() { _stage = _Stage.selectingRoi; _statusMsg = ''; });
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: AppColors.red));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg0,
      appBar: AppBar(
        title: Text(widget.resumeDraft != null ? '继续处理' : '添加错题'),
        actions: [
          if (_stage == _Stage.selectingRoi)
            IconButton(icon: const Icon(Icons.photo_library_outlined),
                tooltip: '重新选图', onPressed: () => _pickImage(ImageSource.gallery)),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    switch (_stage) {
      case _Stage.idle: return _buildIdle();
      case _Stage.uploading: return _buildLoading('上传图片…', progress: _uploadProgress);
      case _Stage.selectingRoi:
        if (_imageFile == null || !_imageFile!.existsSync()) return _buildImageMissing();
        return RoiSelector(imageFile: _imageFile!, imageWidthPx: _uploadResp!.widthPx,
            imageHeightPx: _uploadResp!.heightPx, onConfirm: _onRoiConfirmed);
      case _Stage.extracting: return _buildLoading(_statusMsg);
    }
  }

  Widget _buildIdle() => Center(child: Padding(padding: const EdgeInsets.all(32), child: Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Container(width: 96, height: 96,
        decoration: BoxDecoration(color: AppColors.bg1, borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppColors.bg3)),
        child: const Icon(Icons.document_scanner_outlined, size: 44, color: AppColors.amber)),
      const SizedBox(height: 28),
      const Text('添加错题', style: TextStyle(color: AppColors.textPrimary, fontSize: 22, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      const Text('拍照或从相册选取试卷图片', style: TextStyle(color: AppColors.textSecondary, fontSize: 14)),
      const SizedBox(height: 36),
      SizedBox(width: double.infinity, child: ElevatedButton.icon(
          onPressed: () => _pickImage(ImageSource.camera),
          icon: const Icon(Icons.camera_alt_outlined), label: const Text('拍照'))),
      const SizedBox(height: 12),
      SizedBox(width: double.infinity, child: OutlinedButton.icon(
        onPressed: () => _pickImage(ImageSource.gallery),
        icon: const Icon(Icons.photo_library_outlined, color: AppColors.textSecondary),
        label: const Text('从相册选取', style: TextStyle(color: AppColors.textSecondary)),
        style: OutlinedButton.styleFrom(side: const BorderSide(color: AppColors.bg3),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
      )),
    ],
  )));

  Widget _buildImageMissing() => Center(child: Padding(padding: const EdgeInsets.all(32), child: Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      const Icon(Icons.image_not_supported_outlined, size: 48, color: AppColors.textMuted),
      const SizedBox(height: 16),
      const Text('原图已被系统清理', style: TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      const Text('服务端图片仍在，请重新从相册选取同一张图再进行框选',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.6)),
      const SizedBox(height: 24),
      ElevatedButton.icon(onPressed: () => _pickImage(ImageSource.gallery),
          icon: const Icon(Icons.photo_library_outlined), label: const Text('重新选图（跳过上传）')),
    ],
  )));

  Widget _buildLoading(String msg, {double? progress}) => Center(child: Padding(
    padding: const EdgeInsets.all(40),
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      if (progress != null && progress > 0 && progress < 1)
        Column(children: [
          LinearProgressIndicator(value: progress, backgroundColor: AppColors.bg2,
              color: AppColors.amber, minHeight: 3, borderRadius: BorderRadius.circular(2)),
          const SizedBox(height: 16),
        ])
      else
        const Padding(padding: EdgeInsets.only(bottom: 20),
            child: SizedBox(width: 40, height: 40,
                child: CircularProgressIndicator(color: AppColors.amber, strokeWidth: 2.5))),
      Text(msg, style: const TextStyle(color: AppColors.textSecondary, fontSize: 14)),
      const SizedBox(height: 8),
      const Text('AI 推理中，请耐心等待…', style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
    ]),
  ));
}
