// lib/widgets/roi_selector.dart
//
// 核心交互组件：在图片上手指拖拽画框选取错题区域
// 坐标自动换算回原图像素（考虑图片缩放比例）
//
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import '../utils/theme.dart';

class RoiSelector extends StatefulWidget {
  final File imageFile;
  final int imageWidthPx;    // 原图宽度（服务端返回）
  final int imageHeightPx;   // 原图高度
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

  // 把 widget 坐标转换为原图像素坐标
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

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ── 提示文字 ────────────────────────────────────────────────────────
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
              const Expanded(
                child: Text(
                  '在图片上拖拽选取错题区域',
                  style: TextStyle(
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

        // ── 图片 + 框选层 ────────────────────────────────────────────────────
        Expanded(
          child: GestureDetector(
            onPanStart: (d) {
              final box = _imageKey.currentContext?.findRenderObject() as RenderBox?;
              if (box == null) return;
              final local = box.globalToLocal(d.globalPosition);
              setState(() { _start = local; _end = local; });
            },
            onPanUpdate: (d) {
              final box = _imageKey.currentContext?.findRenderObject() as RenderBox?;
              if (box == null) return;
              final local = box.globalToLocal(d.globalPosition);
              setState(() { _end = local; });
            },
            onPanEnd: (_) {
              // 框选完成，不自动确认，让用户点按钮
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 原图
                Image.file(
                  widget.imageFile,
                  key: _imageKey,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                ),
                // 选框覆盖层
                if (_hasSelection)
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _RoiPainter(
                        start: _start!,
                        end: _end!,
                        imageKey: _imageKey,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),

        // ── 确认按钮 ─────────────────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.all(16),
          color: AppColors.bg1,
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _hasSelection
                  ? () => widget.onConfirm(
                        _toImageCoords(_start!, _end!))
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

// ── 选框绘制器 ────────────────────────────────────────────────────────────────
class _RoiPainter extends CustomPainter {
  final Offset start;
  final Offset end;
  final GlobalKey imageKey;

  _RoiPainter({required this.start, required this.end, required this.imageKey});

  @override
  void paint(Canvas canvas, Size size) {
    final box = imageKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;

    // 图片在 Stack 中的偏移（BoxFit.contain 留边）
    final imgSize = box.size;
    final imgOffset = box.localToGlobal(Offset.zero);
    final stackOffset = (imageKey.currentContext
        ?.findAncestorRenderObjectOfType<RenderBox>())
        ?.globalToLocal(imgOffset) ?? Offset.zero;

    final rect = Rect.fromPoints(
      start + stackOffset,
      end + stackOffset,
    );

    // 半透明遮罩
    final maskPaint = Paint()..color = Colors.black45;
    canvas.drawRect(Offset.zero & size, maskPaint);

    // 清除选区内的遮罩
    canvas.drawRect(rect, Paint()..blendMode = BlendMode.clear);

    // 选框边线
    final borderPaint = Paint()
      ..color = AppColors.amber
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawRect(rect, borderPaint);

    // 四角加粗
    _drawCorners(canvas, rect);

    // 尺寸标注
    final w = (end.dx - start.dx).abs();
    final h = (end.dy - start.dy).abs();
    final label = '${w.toStringAsFixed(0)} × ${h.toStringAsFixed(0)}';
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
    tp.paint(canvas, rect.topLeft + const Offset(4, -18));
  }

  void _drawCorners(Canvas canvas, Rect rect) {
    const len = 12.0;
    final p = Paint()
      ..color = AppColors.amber
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // 左上
    canvas.drawLine(rect.topLeft, rect.topLeft + const Offset(len, 0), p);
    canvas.drawLine(rect.topLeft, rect.topLeft + const Offset(0, len), p);
    // 右上
    canvas.drawLine(rect.topRight, rect.topRight + const Offset(-len, 0), p);
    canvas.drawLine(rect.topRight, rect.topRight + const Offset(0, len), p);
    // 左下
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft + const Offset(len, 0), p);
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft + const Offset(0, -len), p);
    // 右下
    canvas.drawLine(rect.bottomRight, rect.bottomRight + const Offset(-len, 0), p);
    canvas.drawLine(rect.bottomRight, rect.bottomRight + const Offset(0, -len), p);
  }

  @override
  bool shouldRepaint(_RoiPainter old) =>
      old.start != start || old.end != end;
}
