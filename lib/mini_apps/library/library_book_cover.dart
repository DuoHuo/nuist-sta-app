import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 在卡片中按原比例展示封面，去掉方形缩略图中可以确认的左右白边。
class LibraryBookCover extends StatefulWidget {
  const LibraryBookCover({super.key, required this.bytes, required this.width});

  final Uint8List bytes;
  final double width;

  @override
  State<LibraryBookCover> createState() => _LibraryBookCoverState();
}

class _LibraryBookCoverState extends State<LibraryBookCover> {
  ui.Image? _image;
  Rect? _source;
  bool _unavailable = false;

  @override
  void initState() {
    super.initState();
    _load(widget.bytes);
  }

  @override
  void didUpdateWidget(LibraryBookCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bytes == widget.bytes) return;
    _image?.dispose();
    _image = null;
    _source = null;
    _unavailable = false;
    _load(widget.bytes);
  }

  Future<void> _load(Uint8List bytes) async {
    ui.Image? image;
    Rect? source;
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final codec = await ui.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: (width, height) {
          const maxSide = 480;
          if (width <= maxSide && height <= maxSide) {
            return const ui.TargetImageSize();
          }
          return width >= height
              ? const ui.TargetImageSize(width: maxSide)
              : const ui.TargetImageSize(height: maxSide);
        },
      );
      try {
        image = (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
      if (image.width == image.height && image.width >= 32) {
        final pixels = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        if (pixels != null) source = paddedCoverSourceRect(pixels, image.width);
      }
    } on Exception {
      // 读取不到像素时仍可展示已解码的原图。
    }
    if (!mounted || widget.bytes != bytes) {
      image?.dispose();
      return;
    }
    setState(() {
      _image = image;
      _source = source;
      _unavailable = image == null;
    });
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_unavailable) return const SizedBox.shrink();
    final image = _image;
    return Semantics(
      label: '图书封面',
      image: true,
      child: SizedBox(
        width: widget.width,
        height: widget.width * 1.42,
        child: image == null
            ? null
            : CustomPaint(
                painter: _CoverPainter(
                  image,
                  _source ??
                      Rect.fromLTWH(
                        0,
                        0,
                        image.width.toDouble(),
                        image.height.toDouble(),
                      ),
                ),
              ),
      ),
    );
  }
}

/// 仅在方形缩略图两侧都有对称白边且封面主体贯穿上下时裁边。
@visibleForTesting
Rect? paddedCoverSourceRect(ByteData pixels, int side) {
  bool isBlank(int x, int y) {
    final index = (y * side + x) * 4;
    return pixels.getUint8(index + 3) < 8 ||
        (pixels.getUint8(index) >= 248 &&
            pixels.getUint8(index + 1) >= 248 &&
            pixels.getUint8(index + 2) >= 248);
  }

  int blankColumns({required bool fromLeft}) {
    for (var inset = 0; inset < side ~/ 4; inset++) {
      final x = fromLeft ? inset : side - inset - 1;
      for (var y = 0; y < side; y++) {
        if (!isBlank(x, y)) return inset;
      }
    }
    return side ~/ 4;
  }

  final left = blankColumns(fromLeft: true);
  final right = blankColumns(fromLeft: false);
  if (left < side / 10 ||
      right < side / 10 ||
      (left - right).abs() > side / 20) {
    return null;
  }

  bool hasArtworkAtEdge(int y) {
    var content = 0;
    for (var x = left; x < side - right; x++) {
      if (!isBlank(x, y)) content++;
    }
    return content >= (side - left - right) / 2;
  }

  if (!hasArtworkAtEdge(0) || !hasArtworkAtEdge(side - 1)) return null;

  // 在内容两侧各留两个像素，保留扫描边缘。
  return Rect.fromLTRB(
    (left - 2).toDouble(),
    0,
    (side - right + 2).toDouble(),
    side.toDouble(),
  );
}

class _CoverPainter extends CustomPainter {
  const _CoverPainter(this.image, this.source);

  final ui.Image image;
  final Rect source;

  @override
  void paint(Canvas canvas, Size size) {
    final fitted = applyBoxFit(BoxFit.contain, source.size, size);
    final destination = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & size,
    );
    canvas.drawImageRect(
      image,
      source,
      destination,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_CoverPainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.source != source;
}
