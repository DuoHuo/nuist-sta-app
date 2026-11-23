import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/colors.dart';
import '../../core/logging/app_log.dart';
import 'bulletin_attachment_preview.dart';
import 'bulletin_attachment_search.dart';

/// 连续显示 PDF 页面，可上下滑动，也可双指缩放整份文档。
class BulletinPdfView extends StatefulWidget {
  /// 复用附件预览已打开的文档和渲染好的首页。
  const BulletinPdfView({
    super.key,
    required this.document,
    required this.firstPage,
    this.searchFile,
    this.searchExpanded = false,
  });

  final BulletinPdfDocument document;
  final Uint8List firstPage;
  final File? searchFile;
  final bool searchExpanded;

  @override
  State<BulletinPdfView> createState() => _BulletinPdfViewState();
}

class _BulletinPdfViewState extends State<BulletinPdfView> {
  static final _log = AppLog.logger('bulletin.attachment');
  static const _gap = 8.0;

  late final _pages = <int, MemoryImage?>{0: MemoryImage(widget.firstPage)};
  double? _pageWidth;
  double _devicePixelRatio = 1.0;
  List<double> _pageOffsets = [];
  ({int first, int last})? _visiblePages;
  bool _renderScheduled = false;
  bool _rendering = false;
  final _transformation = TransformationController();
  BulletinLiveSearch<List<BulletinPdfMatch>>? _search;
  List<BulletinPdfMatch>? _highlightedResult;
  final _highlights = <int, List<({int index, List<Rect> rects})>>{};
  Size _viewportSize = Size.zero;

  @override
  void initState() {
    super.initState();
    final file = widget.searchFile;
    if (file != null) {
      _search = BulletinLiveSearch<List<BulletinPdfMatch>>(
        (query, matchCase) => findBulletinPdfText(file, query, matchCase),
        (matches) => matches.length,
      )..addListener(_updateSearch);
    }
  }

  @override
  void didUpdateWidget(covariant BulletinPdfView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchExpanded && !widget.searchExpanded) {
      _search?.updateText('');
    }
  }

  void _updateSearch() {
    final search = _search!;
    final results = search.result;
    final index = search.selectedIndex;
    setState(() {
      if (!identical(_highlightedResult, results)) {
        _highlightedResult = results;
        _highlights.clear();
        for (final (index, match)
            in (results ?? const <BulletinPdfMatch>[]).indexed) {
          (_highlights[match.page] ??= []).add((
            index: index,
            rects: match.rects,
          ));
        }
      }
    });
    if (results != null && results.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            identical(search.result, results) &&
            search.selectedIndex == index) {
          _revealMatch(results[index]);
        }
      });
    }
  }

  void _revealMatch(BulletinPdfMatch match) {
    if (_viewportSize.isEmpty ||
        _pageOffsets.isEmpty ||
        match.rects.isEmpty ||
        match.page < 0 ||
        match.page >= _pageCount) {
      return;
    }
    final pageTop = _pageOffsets[match.page];
    final pageSize = Size(
      _pageWidth!,
      _pageOffsets[match.page + 1] - pageTop - _gap,
    );
    final bounds = match.rects.reduce(
      (bounds, rect) => bounds.expandToInclude(rect),
    );
    final target = Rect.fromLTRB(
      _gap + bounds.left * pageSize.width,
      pageTop + bounds.top * pageSize.height,
      _gap + bounds.right * pageSize.width,
      pageTop + bounds.bottom * pageSize.height,
    );
    final transform = _transformation.value;
    final visible = MatrixUtils.transformRect(transform, target);
    final scale = transform.getMaxScaleOnAxis();
    final translation = transform.getTranslation();

    double revealAxis(
      double start,
      double end,
      double viewport,
      double extent,
      double offset,
    ) {
      if (start >= 0 && end <= viewport) return offset;
      // 保留当前缩放。能放下整项时居中，跨越屏幕的大段文字从开头显示。
      final destination = end - start <= viewport
          ? (viewport - end - start) / 2
          : 12 - start;
      return (offset + destination).clamp(
        math.min(0.0, viewport - extent * scale),
        0.0,
      );
    }

    final x = revealAxis(
      visible.left,
      visible.right,
      _viewportSize.width,
      _viewportSize.width,
      translation.x,
    );
    final y = revealAxis(
      visible.top,
      visible.bottom,
      _viewportSize.height,
      math.max(_viewportSize.height, _pageOffsets.last),
      translation.y,
    );
    if (x != translation.x || y != translation.y) {
      _transformation.value = transform.clone()
        ..setTranslationRaw(x, y, translation.z);
    }
  }

  int get _pageCount => widget.document.pageAspectRatios.length;

  void _layoutPages(double width) {
    if (_pageWidth == width) return;
    _pageWidth = width;
    final offsets = [_gap];
    for (final ratio in widget.document.pageAspectRatios) {
      offsets.add(offsets.last + width / ratio + _gap);
    }
    _pageOffsets = offsets;
  }

  int _pageAt(double offset) {
    var low = 0;
    var high = _pageCount - 1;
    while (low < high) {
      final middle = (low + high + 1) ~/ 2;
      if (_pageOffsets[middle] <= offset) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    return low;
  }

  void _requestPages(int first, int last) {
    _visiblePages = (first: first, last: last);
    if (_renderScheduled || _rendering) return;
    _renderScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _renderScheduled = false;
      if (mounted) unawaited(_renderNextPage());
    });
  }

  Future<void> _renderNextPage() async {
    final (:first, :last) = _visiblePages!;
    final firstCached = math.max(0, first - 2);
    final lastCached = math.min(_pageCount - 1, last + 2);
    _pages.removeWhere((index, image) {
      if (index >= firstCached && index <= lastCached) return false;
      if (image != null) PaintingBinding.instance.imageCache.evict(image);
      return true;
    });

    // 一次只提交一页，快速滑过时让新进入屏幕的页面优先。
    final candidates = [
      for (var index = first; index <= last; index++) index,
      if (last + 1 < _pageCount) last + 1,
      if (first > 0) first - 1,
    ];
    for (final index in candidates) {
      if (_pages.containsKey(index)) continue;
      _rendering = true;
      MemoryImage? image;
      final targetWidth = ((_pageWidth ?? 800) * _devicePixelRatio)
          .round()
          .clamp(320, 1600);
      try {
        image = MemoryImage(
          await widget.document.renderPage(index, targetWidth: targetWidth),
        );
      } catch (error, stackTrace) {
        // 单页失败仍可继续浏览其他页面。
        _log.warning(
          'pdf.render_failed',
          fields: {'stage': 'attachment.render_pdf', 'outcome': 'degraded'},
          error: error,
          stackTrace: stackTrace,
        );
      }
      if (!mounted) return;
      setState(() {
        _pages[index] = image;
        _rendering = false;
      });
      return;
    }
  }

  @override
  void dispose() {
    _search?.dispose();
    _transformation.dispose();
    for (final image in _pages.values.nonNulls) {
      PaintingBinding.instance.imageCache.evict(image);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final palette = AppPalette.of(context);
    final search = _search;
    if (search == null) return _buildReader(palette);
    return Column(
      children: [
        if (widget.searchExpanded) BulletinSearchField(search: search),
        Expanded(child: _buildReader(palette)),
      ],
    );
  }

  Widget _buildReader(AppPalette palette) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewportSize = constraints.biggest;
        final width = constraints.maxWidth;
        _layoutPages(math.max(1.0, width - _gap * 2));
        return InteractiveViewer.builder(
          transformationController: _transformation,
          minScale: 1,
          maxScale: 4,
          builder: (context, viewport) {
            final first = _pageAt(viewport.point0.y);
            final last = _pageAt(viewport.point2.y);
            _requestPages(first, last);
            return SizedBox(
              width: width,
              height: math.max(constraints.maxHeight, _pageOffsets.last),
              child: Stack(
                children: [
                  for (var index = first; index <= last; index++)
                    Positioned(
                      key: ValueKey(index),
                      left: _gap,
                      right: _gap,
                      top: _pageOffsets[index],
                      height:
                          _pageOffsets[index + 1] - _pageOffsets[index] - _gap,
                      child: _buildPage(index, palette),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPage(int index, AppPalette palette) {
    final image = _pages[index];
    return ColoredBox(
      color: palette.surface,
      child: image == null
          ? Center(
              child: _pages.containsKey(index)
                  ? const Text('此页无法预览')
                  : SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(
                        color: palette.accent,
                        strokeWidth: 2,
                      ),
                    ),
            )
          : CustomPaint(
              foregroundPainter: _highlights[index] == null
                  ? null
                  : _PdfHighlights(
                      _highlights[index]!,
                      _search!.selectedIndex,
                      palette.searchHighlight,
                      palette.searchCurrentHighlight,
                    ),
              child: Image(
                image: image,
                fit: BoxFit.contain,
                semanticLabel: '第 ${index + 1} 页',
                errorBuilder: (context, error, stackTrace) =>
                    const Center(child: Text('此页无法预览')),
              ),
            ),
    );
  }
}

class _PdfHighlights extends CustomPainter {
  const _PdfHighlights(
    this.groups,
    this.selected,
    this.color,
    this.currentColor,
  );

  final List<({int index, List<Rect> rects})> groups;
  final int selected;
  final Color color;
  final Color currentColor;

  @override
  void paint(Canvas canvas, Size size) {
    // 正片叠底只染亮色背景，深色笔画仍保持清晰。描边让深色底上的命中也可辨认。
    final fill = Paint()..blendMode = BlendMode.multiply;
    final border = Paint()..style = PaintingStyle.stroke;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final group in groups) {
      final current = group.index == selected;
      fill.color = current
          ? currentColor.withValues(alpha: .22)
          : color.withValues(alpha: .76);
      border
        ..color = current ? currentColor : color.withValues(alpha: .85)
        ..strokeWidth = current ? 3 : 1;
      for (final rect in group.rects) {
        final bounds = Rect.fromLTRB(
          rect.left * size.width,
          rect.top * size.height,
          rect.right * size.width,
          rect.bottom * size.height,
        );
        canvas.drawRect(bounds, fill);
        canvas.drawRect(bounds.inflate(border.strokeWidth / 2), border);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PdfHighlights old) =>
      old.groups != groups ||
      old.selected != selected ||
      old.color != color ||
      old.currentColor != currentColor;
}
