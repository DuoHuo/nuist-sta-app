import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../core/app_snack_bar.dart';
import '../../../core/colors.dart';
import '../../../core/logging/app_log.dart';

/// 手动裁剪相册图片，返回 512×512 PNG；直接返回则放弃本次修改。
class AppIconCropPage extends StatefulWidget {
  const AppIconCropPage({super.key, required this.imageBytes});

  final Uint8List imageBytes;

  @override
  State<AppIconCropPage> createState() => _AppIconCropPageState();
}

class _AppIconCropPageState extends State<AppIconCropPage> {
  static const _outputSize = 512.0;
  static final _log = AppLog.logger('app_icon.crop');
  final _viewer = TransformationController();
  final _boundary = GlobalKey();
  bool _exporting = false;
  ui.Image? _image;
  bool _decodeFailed = false;
  double? _viewportSide;
  double? _displayScale;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    try {
      final image = await _log.operation('image.decode', () async {
        final codec = await ui.instantiateImageCodec(widget.imageBytes);
        try {
          return (await codec.getNextFrame()).image;
        } finally {
          codec.dispose();
        }
      }, successLevel: AppLogLevel.debug);
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() => _image = image);
    } catch (_) {
      if (mounted) setState(() => _decodeFailed = true);
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    _viewer.dispose();
    super.dispose();
  }

  /// 让原图以最小 cover 比例居中；原图四边始终可拖动到方框内。
  void _prepareViewport(double side) {
    final image = _image;
    if (image == null) return;
    final displayScale = image.width >= image.height
        ? side / image.height
        : side / image.width;
    if (_viewportSide == side && _displayScale == displayScale) return;
    final previousSide = _viewportSide;
    _viewportSide = side;
    _displayScale = displayScale;
    if (previousSide != null && previousSide > 0) {
      // 屏幕旋转或可用空间变化时按方框比例调整平移，保留原图采样区域。
      final ratio = side / previousSide;
      _viewer.value = Matrix4.copy(_viewer.value)
        ..setTranslationRaw(
          _viewer.value.storage[12] * ratio,
          _viewer.value.storage[13] * ratio,
          _viewer.value.storage[14],
        );
      return;
    }
    final width = image.width * displayScale;
    final height = image.height * displayScale;
    // child 已是 cover 后的尺寸，矩阵只负责平移，初始缩放必须为 1。
    _viewer.value = Matrix4.identity()
      ..translateByDouble((side - width) / 2, (side - height) / 2, 0, 1);
  }

  /// 按当前可见的正方形区域直接从原图采样，生成完整方形的 512×512 PNG。
  ///
  /// 不截取 UI 图层，因此不会包含背景或预览圆角；矩阵坐标先逆变换到
  /// cover 后的 child 坐标，再除以显示比例得到原图采样区域。
  Future<Uint8List?> _export() async {
    if (_exporting || _image == null) return null;
    setState(() => _exporting = true);
    try {
      return await _log.operation('image.export', () async {
        final image = _image!;
        final side = _viewportSide;
        final displayScale = _displayScale;
        if (side == null || displayScale == null) {
          throw StateError('裁剪区域尚未准备好');
        }
        final inverse = Matrix4.inverted(_viewer.value);
        final topLeft = MatrixUtils.transformPoint(inverse, Offset.zero);
        final bottomRight = MatrixUtils.transformPoint(
          inverse,
          Offset(side, side),
        );
        var source = Rect.fromLTRB(
          topLeft.dx / displayScale,
          topLeft.dy / displayScale,
          bottomRight.dx / displayScale,
          bottomRight.dy / displayScale,
        );
        final bounds = Rect.fromLTWH(
          0,
          0,
          image.width.toDouble(),
          image.height.toDouble(),
        );
        // 任何越界都会把背景色带进桌面图标；宁可失败让用户重新调整，
        // 也不生成带空白边缘的图片。
        if (source.isEmpty ||
            source.left < bounds.left - 0.5 ||
            source.top < bounds.top - 0.5 ||
            source.right > bounds.right + 0.5 ||
            source.bottom > bounds.bottom + 0.5) {
          throw StateError('裁剪区域超出图片边界');
        }
        source = source.intersect(bounds);
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawImageRect(
          image,
          source,
          const Rect.fromLTWH(0, 0, _outputSize, _outputSize),
          Paint()..filterQuality = FilterQuality.high,
        );
        final picture = recorder.endRecording();
        ui.Image? rendered;
        try {
          rendered = await picture.toImage(
            _outputSize.toInt(),
            _outputSize.toInt(),
          );
          final data = await rendered.toByteData(
            format: ui.ImageByteFormat.png,
          );
          if (data == null) throw StateError('图片编码失败');
          return data.buffer.asUint8List();
        } finally {
          rendered?.dispose();
          picture.dispose();
        }
      }, successLevel: AppLogLevel.debug);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          AppSnackBar(
            tone: AppSnackBarTone.error,
            content: const Text('裁剪失败，请重试'),
          ),
        );
      }
      return null;
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _confirm() async {
    final bytes = await _export();
    // 导出结束后先让 PopScope 恢复可返回，再把结果交给真实路由入口。
    if (bytes != null && mounted) await WidgetsBinding.instance.endOfFrame;
    if (bytes != null && mounted) Navigator.of(context).pop(bytes);
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return PopScope<Object?>(
      canPop: !_exporting,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('裁剪图标'),
          actions: [
            TextButton(
              onPressed: _image == null || _exporting ? null : _confirm,
              child: const Text('完成'),
            ),
          ],
        ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 滚动容器让空间不足时方框保持真实正方形，避免父约束只压缩
              // 预览高度，而导出仍按原来的边长采样。宽度不超出安全区域。
              final side = constraints.biggest.shortestSide
                  .clamp(160.0, 420.0)
                  .clamp(0.0, constraints.maxWidth)
                  .toDouble();
              _prepareViewport(side);
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                        child: Text(
                          '拖动图片调整位置，双指缩放。方框内的内容会用作图标。',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: palette.labelText,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Center(
                          child: Builder(
                            builder: (context) {
                              final image = _image;
                              final displayScale = _displayScale;
                              return SizedBox.square(
                                dimension: side,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    // 圆角只用于屏幕预览，位于截图边界之外；输出保持完整方形。
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(20),
                                      child: RepaintBoundary(
                                        key: _boundary,
                                        child: ColoredBox(
                                          color: palette.surface,
                                          child: image == null
                                              ? _CropPlaceholder(
                                                  failed: _decodeFailed,
                                                )
                                              : ClipRect(
                                                  child: InteractiveViewer(
                                                    transformationController:
                                                        _viewer,
                                                    constrained: false,
                                                    boundaryMargin:
                                                        EdgeInsets.zero,
                                                    minScale: 1,
                                                    maxScale: 6,
                                                    panEnabled: !_exporting,
                                                    scaleEnabled: !_exporting,
                                                    child: SizedBox(
                                                      width:
                                                          image.width *
                                                          displayScale!,
                                                      height:
                                                          image.height *
                                                          displayScale,
                                                      child: RawImage(
                                                        image: image,
                                                        fit: BoxFit.fill,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                        ),
                                      ),
                                    ),
                                    IgnorePointer(
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(
                                            20,
                                          ),
                                          border: Border.all(
                                            color: palette.accent.withValues(
                                              alpha: 0.7,
                                            ),
                                            width: 2,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                        child: Text(
                          '系统会按桌面图标样式处理边缘',
                          style: TextStyle(color: palette.hint, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _CropPlaceholder extends StatelessWidget {
  const _CropPlaceholder({required this.failed});

  final bool failed;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            failed ? Icons.broken_image_outlined : Icons.image_outlined,
            size: 36,
            color: palette.hint,
          ),
          const SizedBox(height: 8),
          Text(
            failed ? '无法读取这张图片' : '正在准备图片…',
            style: TextStyle(color: palette.labelText, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
