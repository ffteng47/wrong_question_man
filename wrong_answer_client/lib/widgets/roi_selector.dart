// lib/widgets/roi_selector.dart
//
// 核心交互组件：在图片上手指拖拽画框选取错题区域（题区 + 可选手写答案区）
// 修复：
//   1. 黑框问题 — 改用四边遮罩代替 BlendMode.clear
//   2. 坐标双重偏移 — painter 直接从 imageKey local 坐标转换到 Stack 坐标
//   3. 新增八方向拖拽手柄，支持调整选区大小
//   4. BoxFit.contain 坐标映射 — _toImageCoords 先减去黑边偏移再计算原图坐标
//   5. 双选区模式 — 题区/答案区切换框选，输出 0~1000 归一化坐标
//
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import '../utils/theme.dart';

enum _Handle {
  none, topLeft, top, topRight, right,
  bottomRight, bottom, bottomLeft, left, move
}

enum _SelMode { question, answer }

class RoiSelector extends StatefulWidget {
  final File imageFile;
  final int imageWidthPx;
  final int imageHeightPx;
  final void Function(List<double> questionBbox, List<double>? answerBbox)
      onConfirm;

  const RoiSelector({
    super.key,
    required this.imageFile,
    required this.imageWidthPx,
    required this.imageHeightPx,
    required this.onConfirm,
  });

  @override
  State<RoiSelector> createState() => _RoiSelectorState();
}

class _RoiSelectorState extends State<RoiSelector>
    with SingleTickerProviderStateMixin {
  // 题区
  Offset? _start;
  Offset? _end;
  // 答案区（可选）
  Offset? _aStart;
  Offset? _aEnd;
  _SelMode _mode = _SelMode.question;

  final _imageKey = GlobalKey();

  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  _Handle _activeHandle = _Handle.none;
  static const double _handleHitRadius = 20.0;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseAnim = Tween(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  /// 计算 BoxFit.contain 后图片在 widget 中的实际渲染区域
  /// 返回 [offsetX, offsetY, renderW, renderH]
  List<double> _computeImageRenderRect(Size widgetSize) {
    final imgW = widget.imageWidthPx.toDouble();
    final imgH = widget.imageHeightPx.toDouble();

    final widgetRatio = widgetSize.width / widgetSize.height;
    final imgRatio = imgW / imgH;

    double renderW, renderH, offsetX, offsetY;
    if (imgRatio > widgetRatio) {
      // 图片更宽，以宽度为准，上下留黑边
      renderW = widgetSize.width;
      renderH = widgetSize.width / imgRatio;
      offsetX = 0;
      offsetY = (widgetSize.height - renderH) / 2;
    } else {
      // 图片更高或等比例，以高度为准，左右留黑边
      renderH = widgetSize.height;
      renderW = widgetSize.height * imgRatio;
      offsetX = (widgetSize.width - renderW) / 2;
      offsetY = 0;
    }

    return [offsetX, offsetY, renderW, renderH];
  }

  /// 选区（widget 局部坐标）→ 原图 0~1000 归一化坐标
  List<double> _toImageCoords(Offset widgetStart, Offset widgetEnd) {
    final box = _imageKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return [0, 0, 1000, 1000];

    final size = box.size;
    final rect = _computeImageRenderRect(size);
    final offsetX = rect[0];
    final offsetY = rect[1];
    final renderW = rect[2];
    final renderH = rect[3];

    final x1 = (min(widgetStart.dx, widgetEnd.dx) - offsetX) / renderW * 1000;
    final y1 = (min(widgetStart.dy, widgetEnd.dy) - offsetY) / renderH * 1000;
    final x2 = (max(widgetStart.dx, widgetEnd.dx) - offsetX) / renderW * 1000;
    final y2 = (max(widgetStart.dy, widgetEnd.dy) - offsetY) / renderH * 1000;

    return [
      x1.clamp(0.0, 1000.0),
      y1.clamp(0.0, 1000.0),
      x2.clamp(0.0, 1000.0),
      y2.clamp(0.0, 1000.0),
    ];
  }

  bool _hasRect(Offset? s, Offset? e) =>
      s != null && e != null &&
      ((e.dx - s.dx).abs() > 10 || (e.dy - s.dy).abs() > 10);

  bool get _hasQuestion => _hasRect(_start, _end);
  bool get _hasAnswer => _hasRect(_aStart, _aEnd);
  bool get _hasActiveSelection =>
      _mode == _SelMode.question ? _hasQuestion : _hasAnswer;

  // 将全局坐标转为 imageKey 的 local 坐标
  Offset? _toImageLocal(Offset global) {
    final box = _imageKey.currentContext?.findRenderObject() as RenderBox?;
    return box?.globalToLocal(global);
  }

  Rect get _activeRect => _mode == _SelMode.question
      ? Rect.fromPoints(_start!, _end!)
      : Rect.fromPoints(_aStart!, _aEnd!);

  void _setActiveRect(Rect r) {
    if (_mode == _SelMode.question) {
      _start = r.topLeft;
      _end = r.bottomRight;
    } else {
      _aStart = r.topLeft;
      _aEnd = r.bottomRight;
    }
  }

  _Handle _hitHandle(Offset local) {
    if (!_hasActiveSelection) return _Handle.none;
    final r = _activeRect;
    final points = <_Handle, Offset>{
      _Handle.topLeft:     r.topLeft,
      _Handle.topRight:    r.topRight,
      _Handle.bottomLeft:  r.bottomLeft,
      _Handle.bottomRight: r.bottomRight,
      _Handle.top:         Offset(r.center.dx, r.top),
      _Handle.bottom:      Offset(r.center.dx, r.bottom),
      _Handle.left:        Offset(r.left, r.center.dy),
      _Handle.right:       Offset(r.right, r.center.dy),
    };
    for (final e in points.entries) {
      if ((local - e.value).distance < _handleHitRadius) return e.key;
    }
    if (r.contains(local)) return _Handle.move;
    return _Handle.none;
  }

  void _applyHandleDrag(_Handle handle, Offset delta) {
    if (!_hasActiveSelection) return;
    final r = _activeRect;
    double x1 = r.left, y1 = r.top, x2 = r.right, y2 = r.bottom;

    final box = _imageKey.currentContext?.findRenderObject() as RenderBox?;
    final size = box?.size ?? Size.zero;
    final rect = _computeImageRenderRect(size);

    // 实际图片渲染区域的边界（widget 局部坐标）
    final minX = rect[0];
    final minY = rect[1];
    final maxX = rect[0] + rect[2];
    final maxY = rect[1] + rect[3];

    switch (handle) {
      case _Handle.topLeft:     x1 += delta.dx; y1 += delta.dy; break;
      case _Handle.top:         y1 += delta.dy; break;
      case _Handle.topRight:    x2 += delta.dx; y1 += delta.dy; break;
      case _Handle.right:       x2 += delta.dx; break;
      case _Handle.bottomRight: x2 += delta.dx; y2 += delta.dy; break;
      case _Handle.bottom:      y2 += delta.dy; break;
      case _Handle.bottomLeft:  x1 += delta.dx; y2 += delta.dy; break;
      case _Handle.left:        x1 += delta.dx; break;
      case _Handle.move:
        final w = x2 - x1; final h = y2 - y1;
        x1 += delta.dx; x2 = x1 + w;
        y1 += delta.dy; y2 = y1 + h;
        break;
      case _Handle.none: return;
    }

    x1 = x1.clamp(minX, maxX - 20);
    y1 = y1.clamp(minY, maxY - 20);
    x2 = x2.clamp(x1 + 20, maxX);
    y2 = y2.clamp(y1 + 20, maxY);

    _setActiveRect(Rect.fromLTRB(x1, y1, x2, y2));
  }

  @override
  Widget build(BuildContext context) {
    final isQ = _mode == _SelMode.question;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          color: AppColors.bg1,
          child: Row(
            children: [
              // 题区 / 答案区切换
              _modeChip('题区', isQ, AppColors.amber,
                  () => setState(() => _mode = _SelMode.question)),
              const SizedBox(width: 8),
              _modeChip('答案区', !isQ, AppColors.green,
                  () => setState(() => _mode = _SelMode.answer)),
              const Spacer(),
              if (_hasActiveSelection)
                TextButton.icon(
                  onPressed: () => setState(() {
                    if (isQ) {
                      _start = null; _end = null;
                    } else {
                      _aStart = null; _aEnd = null;
                    }
                  }),
                  icon: const Icon(Icons.refresh, size: 14),
                  label: Text(isQ ? '重选题区' : '重选答案',
                      style: const TextStyle(fontSize: 13)),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
          color: AppColors.bg1,
          child: Row(
            children: [
              AnimatedBuilder(
                animation: _pulseAnim,
                builder: (_, __) => Opacity(
                  opacity: _pulseAnim.value,
                  child: const Icon(Icons.touch_app,
                      size: 16, color: AppColors.amber),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _hasActiveSelection
                      ? '拖动角点/边线调整选区，或切换区域重新画框'
                      : isQ
                          ? '在图片上拖拽选取题目区域'
                          : '框选手写答案区域（可不选）',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),

        Expanded(
          child: GestureDetector(
            onPanStart: (d) {
              final local = _toImageLocal(d.globalPosition);
              if (local == null) return;

              final handle = _hitHandle(local);
              if (handle != _Handle.none) {
                setState(() => _activeHandle = handle);
                return;
              }

              // 在当前模式开始新画框
              setState(() {
                _activeHandle = _Handle.none;
                if (_mode == _SelMode.question) {
                  _start = local; _end = local;
                } else {
                  _aStart = local; _aEnd = local;
                }
              });
            },
            onPanUpdate: (d) {
              final local = _toImageLocal(d.globalPosition);
              if (local == null) return;
              setState(() {
                if (_activeHandle != _Handle.none) {
                  _applyHandleDrag(_activeHandle, d.delta);
                } else if (_mode == _SelMode.question) {
                  _end = local;
                } else {
                  _aEnd = local;
                }
              });
            },
            onPanEnd: (_) {
              setState(() => _activeHandle = _Handle.none);
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.file(
                  widget.imageFile,
                  key: _imageKey,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                ),
                if (_hasQuestion || _hasAnswer)
                  Positioned.fill(
                    child: _SelectionOverlay(
                      questionStart: _start,
                      questionEnd: _end,
                      answerStart: _aStart,
                      answerEnd: _aEnd,
                      activeMode: _mode,
                      imageKey: _imageKey,
                    ),
                  ),
              ],
            ),
          ),
        ),

        Container(
          padding: const EdgeInsets.all(16),
          color: AppColors.bg1,
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _hasQuestion
                  ? () => widget.onConfirm(
                      _toImageCoords(_start!, _end!),
                      _hasAnswer
                          ? _toImageCoords(_aStart!, _aEnd!)
                          : null)
                  : null,
              icon: const Icon(Icons.crop, size: 18),
              label: const Text('确认选区，开始分析'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _modeChip(
      String label, bool active, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: active ? color.withOpacity(0.15) : AppColors.bg2,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: active ? color : AppColors.bg3),
        ),
        child: Text(label, style: TextStyle(
            color: active ? color : AppColors.textSecondary,
            fontSize: 13,
            fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
      ),
    );
  }
}

// ── 选框覆盖层（四边遮罩代替 BlendMode.clear，规避黑框问题）─────────────────
class _SelectionOverlay extends StatelessWidget {
  final Offset? questionStart, questionEnd;
  final Offset? answerStart, answerEnd;
  final _SelMode activeMode;
  final GlobalKey imageKey;

  const _SelectionOverlay({
    required this.questionStart,
    required this.questionEnd,
    required this.answerStart,
    required this.answerEnd,
    required this.activeMode,
    required this.imageKey,
  });

  @override
  Widget build(BuildContext context) {
    // 把 imageKey local 坐标转成当前 overlay 坐标
    // overlay 是 Positioned.fill，与 Stack 同原点
    // imageKey widget 在 Stack 内可能有偏移（BoxFit.contain 留边）
    final box = imageKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return const SizedBox.shrink();

    // 图片左上角在 Stack 中的位置
    RenderBox? stackBox;
    RenderObject? cur = box.parent;
    while (cur != null) {
      if (cur is RenderBox && cur != box) { stackBox = cur; break; }
      cur = cur.parent;
    }
    final imgTopLeft = stackBox != null
        ? stackBox.globalToLocal(box.localToGlobal(Offset.zero))
        : Offset.zero;

    Rect? qRect, aRect;
    if (questionStart != null && questionEnd != null) {
      qRect = Rect.fromPoints(
          questionStart! + imgTopLeft, questionEnd! + imgTopLeft);
    }
    if (answerStart != null && answerEnd != null) {
      aRect = Rect.fromPoints(
          answerStart! + imgTopLeft, answerEnd! + imgTopLeft);
    }

    final qActive = activeMode == _SelMode.question && qRect != null;
    final aActive = activeMode == _SelMode.answer && aRect != null;

    return CustomPaint(
      painter: _RoiPainter(
        activeRect: qActive ? qRect : (aActive ? aRect : null),
        activeIsQuestion: qActive,
        inactiveQuestionRect: qActive ? null : qRect,
        inactiveAnswerRect: aActive ? null : aRect,
      ),
    );
  }
}

// ── CustomPainter（纯绘制，不处理坐标转换）──────────────────────────────────
class _RoiPainter extends CustomPainter {
  final Rect? activeRect;            // 当前编辑中的选区（遮罩+手柄）
  final bool activeIsQuestion;
  final Rect? inactiveQuestionRect;  // 非编辑态：仅描边提示
  final Rect? inactiveAnswerRect;

  _RoiPainter({
    this.activeRect,
    this.activeIsQuestion = true,
    this.inactiveQuestionRect,
    this.inactiveAnswerRect,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = activeRect;
    if (rect != null) {
      final maskPaint = Paint()..color = Colors.black.withOpacity(0.45);

      // 四边遮罩（完全避开 BlendMode.clear 的黑框问题）
      canvas.drawRect(Rect.fromLTRB(0, 0, size.width, rect.top), maskPaint);
      canvas.drawRect(
          Rect.fromLTRB(0, rect.bottom, size.width, size.height), maskPaint);
      canvas.drawRect(
          Rect.fromLTRB(0, rect.top, rect.left, rect.bottom), maskPaint);
      canvas.drawRect(
          Rect.fromLTRB(rect.right, rect.top, size.width, rect.bottom),
          maskPaint);

      final color = activeIsQuestion ? AppColors.amber : AppColors.green;
      canvas.drawRect(
        rect,
        Paint()
          ..color = color
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );

      _drawCorners(canvas, rect, color);
      _drawMidHandles(canvas, rect, color);

      final label = '${rect.width.toStringAsFixed(0)} × '
          '${rect.height.toStringAsFixed(0)}';
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontFamily: 'monospace',
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final labelY = rect.top > 20 ? rect.top - 18 : rect.bottom + 4;
      tp.paint(canvas, Offset(rect.left + 4, labelY));
    }

    // 非编辑区域：纯描边提示
    if (inactiveQuestionRect != null) {
      _strokeOnly(canvas, inactiveQuestionRect!,
          AppColors.amber.withOpacity(0.6));
    }
    if (inactiveAnswerRect != null) {
      _strokeOnly(canvas, inactiveAnswerRect!, AppColors.green.withOpacity(0.6));
    }
  }

  void _strokeOnly(Canvas canvas, Rect r, Color color) {
    canvas.drawRect(
      r,
      Paint()
        ..color = color
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );
  }

  void _drawCorners(Canvas canvas, Rect r, Color color) {
    const len = 14.0;
    final p = Paint()
      ..color = color
      ..strokeWidth = 3.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    for (final corner in [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]) {
      final sx = corner == r.topLeft || corner == r.bottomLeft ? 1.0 : -1.0;
      final sy = corner == r.topLeft || corner == r.topRight ? 1.0 : -1.0;
      canvas.drawLine(corner, corner + Offset(len * sx, 0), p);
      canvas.drawLine(corner, corner + Offset(0, len * sy), p);
    }
  }

  void _drawMidHandles(Canvas canvas, Rect r, Color color) {
    const radius = 5.5;
    final fill = Paint()..color = color;
    final stroke = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    for (final pt in [
      Offset(r.center.dx, r.top),
      Offset(r.center.dx, r.bottom),
      Offset(r.left,  r.center.dy),
      Offset(r.right, r.center.dy),
    ]) {
      canvas.drawCircle(pt, radius, fill);
      canvas.drawCircle(pt, radius, stroke);
    }
  }

  @override
  bool shouldRepaint(_RoiPainter old) =>
      old.activeRect != activeRect ||
      old.activeIsQuestion != activeIsQuestion ||
      old.inactiveQuestionRect != inactiveQuestionRect ||
      old.inactiveAnswerRect != inactiveAnswerRect;
}
