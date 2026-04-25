// lib/widgets/roi_selector.dart
//
// 核心交互组件：在图片上手指拖拽画框选取错题区域
// 修复：
//   1. 黑框问题 — 改用四边遮罩代替 BlendMode.clear
//   2. 坐标双重偏移 — painter 直接从 imageKey local 坐标转换到 Stack 坐标
//   3. 新增八方向拖拽手柄，支持调整选区大小
//
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import '../utils/theme.dart';

enum _Handle {
  none, topLeft, top, topRight, right,
  bottomRight, bottom, bottomLeft, left, move
}

class RoiSelector extends StatefulWidget {
  final File imageFile;
  final int imageWidthPx;
  final int imageHeightPx;
  final void Function(List<double> roiBbox) onConfirm;

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
  Offset? _start;
  Offset? _end;
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

  List<double> _toImageCoords(Offset widgetStart, Offset widgetEnd) {
    final box = _imageKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return [0, 0, 100, 100];

    final size = box.size;
    final scaleX = widget.imageWidthPx / size.width;
    final scaleY = widget.imageHeightPx / size.height;

    final x1 = min(widgetStart.dx, widgetEnd.dx) * scaleX;
    final y1 = min(widgetStart.dy, widgetEnd.dy) * scaleY;
    final x2 = max(widgetStart.dx, widgetEnd.dx) * scaleX;
    final y2 = max(widgetStart.dy, widgetEnd.dy) * scaleY;

    return [
      x1.clamp(0, widget.imageWidthPx.toDouble()),
      y1.clamp(0, widget.imageHeightPx.toDouble()),
      x2.clamp(0, widget.imageWidthPx.toDouble()),
      y2.clamp(0, widget.imageHeightPx.toDouble()),
    ];
  }

  bool get _hasSelection =>
      _start != null && _end != null &&
      ((_end!.dx - _start!.dx).abs() > 10 ||
       (_end!.dy - _start!.dy).abs() > 10);

  // 将全局坐标转为 imageKey 的 local 坐标
  Offset? _toImageLocal(Offset global) {
    final box = _imageKey.currentContext?.findRenderObject() as RenderBox?;
    return box?.globalToLocal(global);
  }

  Rect get _selectionRect => Rect.fromPoints(_start!, _end!);

  _Handle _hitHandle(Offset local) {
    if (!_hasSelection) return _Handle.none;
    final r = _selectionRect;
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
    if (_start == null || _end == null) return;
    double x1 = min(_start!.dx, _end!.dx);
    double y1 = min(_start!.dy, _end!.dy);
    double x2 = max(_start!.dx, _end!.dx);
    double y2 = max(_start!.dy, _end!.dy);

    final box = _imageKey.currentContext?.findRenderObject() as RenderBox?;
    final imgW = box?.size.width ?? double.infinity;
    final imgH = box?.size.height ?? double.infinity;

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

    x1 = x1.clamp(0, imgW - 20);
    y1 = y1.clamp(0, imgH - 20);
    x2 = x2.clamp(x1 + 20, imgW);
    y2 = y2.clamp(y1 + 20, imgH);

    _start = Offset(x1, y1);
    _end   = Offset(x2, y2);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
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
                  _hasSelection
                      ? '拖动角点/边线调整选区，或重新拖拽画框'
                      : '在图片上拖拽选取错题区域',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ),
              if (_hasSelection)
                TextButton.icon(
                  onPressed: () => setState(() { _start = null; _end = null; }),
                  icon: const Icon(Icons.refresh, size: 14),
                  label: const Text('重选', style: TextStyle(fontSize: 13)),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
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

              // 开始新画框
              setState(() {
                _activeHandle = _Handle.none;
                _start = local;
                _end = local;
              });
            },
            onPanUpdate: (d) {
              final local = _toImageLocal(d.globalPosition);
              if (local == null) return;
              setState(() {
                if (_activeHandle != _Handle.none) {
                  _applyHandleDrag(_activeHandle, d.delta);
                } else {
                  _end = local;
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
                if (_hasSelection)
                  Positioned.fill(
                    child: _SelectionOverlay(
                      start: _start!,
                      end: _end!,
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
              onPressed: _hasSelection
                  ? () => widget.onConfirm(_toImageCoords(_start!, _end!))
                  : null,
              icon: const Icon(Icons.crop, size: 18),
              label: const Text('确认选区，开始分析'),
            ),
          ),
        ),
      ],
    );
  }
}

// ── 选框覆盖层（用 Stack + 四个遮罩 Widget 代替 CustomPaint BlendMode）──────
class _SelectionOverlay extends StatelessWidget {
  final Offset start;
  final Offset end;
  final GlobalKey imageKey;

  const _SelectionOverlay({
    required this.start,
    required this.end,
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
    // 父级 RenderBox（Stack）
    RenderBox? stackBox;
    RenderObject? cur = box.parent;
    while (cur != null) {
      if (cur is RenderBox && cur != box) { stackBox = cur; break; }
      cur = cur.parent;
    }
    final imgTopLeft = stackBox != null
        ? stackBox.globalToLocal(box.localToGlobal(Offset.zero))
        : Offset.zero;

    final s = start + imgTopLeft;
    final e = end   + imgTopLeft;
    final rect = Rect.fromPoints(s, e);

    return CustomPaint(
      painter: _RoiPainter(rect: rect),
    );
  }
}

// ── CustomPainter（纯绘制，不处理坐标转换）──────────────────────────────────
class _RoiPainter extends CustomPainter {
  final Rect rect;
  _RoiPainter({required this.rect});

  @override
  void paint(Canvas canvas, Size size) {
    final maskColor = Colors.black.withOpacity(0.45);
    final maskPaint = Paint()..color = maskColor;

    // 四边遮罩（完全避开 BlendMode.clear 的黑框问题）
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width, rect.top), maskPaint);
    canvas.drawRect(Rect.fromLTRB(0, rect.bottom, size.width, size.height), maskPaint);
    canvas.drawRect(Rect.fromLTRB(0, rect.top, rect.left, rect.bottom), maskPaint);
    canvas.drawRect(Rect.fromLTRB(rect.right, rect.top, size.width, rect.bottom), maskPaint);

    // 边框
    canvas.drawRect(
      rect,
      Paint()
        ..color = AppColors.amber
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );

    // 四角粗线
    _drawCorners(canvas, rect);

    // 边中点小圆手柄
    _drawMidHandles(canvas, rect);

    // 尺寸标注
    final label = '${rect.width.toStringAsFixed(0)} × ${rect.height.toStringAsFixed(0)}';
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          color: AppColors.amber,
          fontSize: 11,
          fontFamily: 'monospace',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final labelY = rect.top > 20 ? rect.top - 18 : rect.bottom + 4;
    tp.paint(canvas, Offset(rect.left + 4, labelY));
  }

  void _drawCorners(Canvas canvas, Rect r) {
    const len = 14.0;
    final p = Paint()
      ..color = AppColors.amber
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

  void _drawMidHandles(Canvas canvas, Rect r) {
    const radius = 5.5;
    final fill   = Paint()..color = AppColors.amber;
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
  bool shouldRepaint(_RoiPainter old) => old.rect != rect;
}