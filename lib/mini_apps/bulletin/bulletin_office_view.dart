import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../core/colors.dart';
import 'bulletin_attachment_preview.dart';
import 'bulletin_attachment_search.dart';

/// 显示 Office 文件的内容预览，表格保留行列布局。
class BulletinOfficeView extends StatefulWidget {
  /// 使用已经在后台解析的内容。
  const BulletinOfficeView({
    super.key,
    required this.document,
    this.searchFile,
    this.searchExpanded = false,
  });

  final BulletinOfficeDocument document;
  final File? searchFile;
  final bool searchExpanded;

  @override
  State<BulletinOfficeView> createState() => _BulletinOfficeViewState();
}

class _BulletinOfficeViewState extends State<BulletinOfficeView> {
  int _sheet = 0;
  int _searchRevision = 0;
  BulletinLiveSearch<BulletinXlsMatches>? _search;

  @override
  void initState() {
    super.initState();
    final file = widget.searchFile;
    if (file != null) {
      _search = BulletinLiveSearch<BulletinXlsMatches>(
        (query, matchCase) => findBulletinXlsText(file, query, matchCase),
        (results) => results.matches.length,
      )..addListener(_updateSearch);
    }
  }

  @override
  void didUpdateWidget(covariant BulletinOfficeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchExpanded && !widget.searchExpanded) {
      _search?.updateText('');
    }
  }

  void _updateSearch() => setState(() => _searchRevision++);

  @override
  void dispose() {
    _search?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final document = widget.document;
    final first = document.sections.firstOrNull;
    final search = _search;
    final result = search?.result;
    final match = result == null || result.matches.isEmpty
        ? null
        : result.matches[search!.selectedIndex];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (search != null && widget.searchExpanded)
          BulletinSearchField(search: search),
        if (match == null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Text(
              document.limited ? '仅预览部分内容，完整内容请用其他应用打开' : '内容预览，原始排版请用其他应用查看',
              style: TextStyle(color: palette.labelText, fontSize: 12),
            ),
          ),
        Expanded(
          child: SelectionArea(
            child: match != null
                ? _buildWorkbook(result!.sheets, match: match)
                : first == null
                ? const Center(child: Text('预览范围内没有单元格内容'))
                : first.rows.isNotEmpty
                ? _buildWorkbook(document.sections)
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: first.slide == null
                        ? (first.blocks.isEmpty
                              ? first.lines.length
                              : first.blocks.length)
                        : document.sections.length,
                    itemBuilder: (context, index) {
                      if (first.slide == null) {
                        if (first.blocks.isNotEmpty) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _OfficeBlockView(block: first.blocks[index]),
                          );
                        }
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            first.lines[index],
                            style: TextStyle(
                              color: palette.titleText,
                              height: 1.6,
                            ),
                          ),
                        );
                      }
                      return _buildSlide(document.sections[index], palette);
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildWorkbook(
    List<BulletinOfficeSection> sheets, {
    BulletinXlsMatch? match,
  }) {
    final selected = match?.sheet ?? _sheet;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: DropdownButton<int>(
            isExpanded: true,
            value: selected,
            items: [
              for (final (index, sheet) in sheets.indexed)
                DropdownMenuItem(
                  value: index,
                  child: Text(
                    sheet.title?.trim().isNotEmpty == true
                        ? sheet.title!
                        : '工作表 ${index + 1}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: sheets.length == 1
                ? null
                : (index) {
                    if (index == null) return;
                    if (match == null) {
                      setState(() => _sheet = index);
                    } else {
                      final search = _search!;
                      search.jumpTo(
                        search.result!.matches.indexWhere(
                          (hit) => hit.sheet == index,
                        ),
                      );
                    }
                  },
          ),
        ),
        Expanded(
          child: _OfficeSheet(
            key: ValueKey((match != null, selected)),
            section: sheets[selected],
            selection: match == null
                ? null
                : (match: match, revision: _searchRevision),
          ),
        ),
      ],
    );
  }

  Widget _buildSlide(BulletinOfficeSection slide, AppPalette palette) => Card(
    color: palette.surface,
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '第 ${slide.slide} 张幻灯片',
            style: TextStyle(
              color: palette.titleText,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          if (slide.lines.isNotEmpty || slide.blocks.isEmpty)
            Text(
              slide.lines.isEmpty ? '此页没有可预览的内容' : slide.lines.join('\n\n'),
              style: TextStyle(color: palette.titleText, height: 1.6),
            ),
          for (final block in slide.blocks)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _OfficeBlockView(block: block),
            ),
        ],
      ),
    ),
  );
}

class _OfficeBlockView extends StatelessWidget {
  const _OfficeBlockView({required this.block});

  final BulletinOfficeBlock block;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final image = block.image;
    if (image != null) {
      return Image(
        image: ResizeImage(
          MemoryImage(image),
          width: 1280,
          height: 1600,
          policy: ResizeImagePolicy.fit,
        ),
        fit: BoxFit.contain,
        errorBuilder: (context, error, stack) => const Text('此图片无法预览'),
      );
    }
    if (block.table.isNotEmpty) {
      final columns = block.table.map((row) => row.length).reduce(math.max);
      return LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: math.max(constraints.maxWidth, 92.0 * columns),
            child: Table(
              border: TableBorder.all(color: palette.divider),
              children: [
                for (final row in block.table)
                  TableRow(
                    decoration: BoxDecoration(color: palette.surface),
                    children: [
                      for (var i = 0; i < columns; i++)
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(
                            i < row.length ? row[i] : '',
                            style: TextStyle(color: palette.titleText),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      );
    }
    return Text(
      block.text ?? '',
      textAlign: switch (block.alignment) {
        'center' => TextAlign.center,
        'right' || 'end' => TextAlign.end,
        'both' => TextAlign.justify,
        _ => TextAlign.start,
      },
      style: TextStyle(
        color: palette.titleText,
        fontSize: switch (block.heading) {
          1 => 21,
          2 => 17,
          _ => 15,
        },
        fontWeight: block.heading == null ? null : FontWeight.w600,
        height: 1.6,
      ),
    );
  }
}

class _OfficeSheet extends StatefulWidget {
  const _OfficeSheet({super.key, required this.section, this.selection});

  final BulletinOfficeSection section;
  final ({BulletinXlsMatch match, int revision})? selection;

  @override
  State<_OfficeSheet> createState() => _OfficeSheetState();
}

class _OfficeSheetState extends State<_OfficeSheet> {
  static const _rowNumberWidth = 48.0;
  static const _columnWidth = 124.0;
  static const _forwardRows = ValueKey('forwardRows');

  BulletinOfficeSection get section => widget.section;

  final _horizontalScroll = ScrollController(keepScrollOffset: false);
  final _verticalScroll = ScrollController(keepScrollOffset: false);
  final _matchTextKey = GlobalKey();
  double _sheetViewportWidth = 0;
  ({int first, int end})? _laidOutColumns;
  late int _anchorRow;
  Key _viewportKey = UniqueKey();

  @override
  void initState() {
    super.initState();
    _anchorRow = widget.selection?.match.row ?? 0;
    _horizontalScroll.addListener(_updateVisibleColumns);
    _scheduleReveal();
  }

  @override
  void didUpdateWidget(covariant _OfficeSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selection != widget.selection) _scheduleReveal();
  }

  void _scheduleReveal({bool reanchored = false}) {
    final selection = widget.selection;
    if (selection == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.selection != selection) return;
      final match = selection.match;
      final columns = _laidOutColumns;
      if (columns != null &&
          (match.column < columns.first || match.column >= columns.end)) {
        final scroll = _horizontalScroll.position;
        final offset =
            _rowNumberWidth +
            match.column * _columnWidth -
            scroll.viewportDimension / 3;
        scroll.jumpTo(offset.clamp(0.0, scroll.maxScrollExtent));
        _scheduleReveal(reanchored: reanchored);
        return;
      }
      final paragraph = _matchParagraph();
      if (paragraph == null) {
        if (!reanchored) {
          // 从目标行重新布局，只挂载附近的行，保留向前和向后滚动的能力。
          setState(() {
            _anchorRow = match.row;
            _viewportKey = UniqueKey();
          });
          _scheduleReveal(reanchored: true);
        }
        return;
      }
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: match.start, extentOffset: match.end),
      );
      if (boxes.isEmpty) return;
      final bounds = boxes
          .map((box) => box.toRect())
          .reduce((bounds, line) => bounds.expandToInclude(line));
      final vertical = RenderAbstractViewport.of(paragraph);
      final horizontal = RenderAbstractViewport.of(vertical.parent!);
      if (_revealAlong(
            _horizontalScroll.position,
            horizontal,
            paragraph,
            bounds,
          ) &&
          columns != _visibleColumnRange()) {
        // 横向换列会重新计算行高，再根据实际文字位置定位纵向。
        _scheduleReveal(reanchored: reanchored);
        return;
      }
      _revealAlong(_verticalScroll.position, vertical, paragraph, bounds);
    });
  }

  RenderParagraph? _matchParagraph() {
    RenderParagraph? paragraph;
    void find(RenderObject object) {
      if (object is RenderParagraph) {
        paragraph = object;
      } else {
        object.visitChildren(find);
      }
    }

    final root = _matchTextKey.currentContext?.findRenderObject();
    if (root != null) find(root);
    return paragraph;
  }

  bool _revealAlong(
    ScrollPosition position,
    RenderAbstractViewport viewport,
    RenderParagraph paragraph,
    Rect bounds,
  ) {
    final visible = MatrixUtils.transformRect(
      paragraph.getTransformTo(viewport),
      bounds,
    );
    final (start, end) = position.axis == Axis.vertical
        ? (visible.top, visible.bottom)
        : (visible.left, visible.right);
    if (start >= 0 && end <= position.viewportDimension) return false;
    final alignment = end - start >= position.viewportDimension ? 0.0 : .38;
    final offset = viewport
        .getOffsetToReveal(paragraph, alignment, rect: bounds)
        .offset;
    final target = offset.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target == position.pixels) return false;
    position.jumpTo(target);
    return true;
  }

  ({int first, int end})? _visibleColumnRange() {
    if (section.columns <= 64) return null;
    final offset = _horizontalScroll.hasClients
        ? _horizontalScroll.offset
        : 0.0;
    final first = ((offset - _rowNumberWidth) / _columnWidth).floor();
    final end =
        ((offset + _sheetViewportWidth - _rowNumberWidth) / _columnWidth)
            .ceil();
    return (
      first: math.max(0, first - 1),
      end: math.min(section.columns, end + 2),
    );
  }

  void _updateVisibleColumns() {
    if (_laidOutColumns != _visibleColumnRange()) setState(() {});
  }

  @override
  void dispose() {
    _horizontalScroll.dispose();
    _verticalScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          _sheetViewportWidth = constraints.maxWidth;
          _laidOutColumns = _visibleColumnRange();
          return SingleChildScrollView(
            controller: _horizontalScroll,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: _rowNumberWidth + _columnWidth * section.columns,
              child: Column(
                children: [
                  _row('', const {}, palette, header: true),
                  Expanded(child: _buildRows(palette)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildRows(AppPalette palette) {
    Widget rowAt(int index) {
      final row = section.rows[index];
      final match = widget.selection?.match;
      return _row(
        row.number.toString(),
        row.cells,
        palette,
        highlights: row.highlights,
        match: match?.row == index ? match : null,
      );
    }

    if (widget.selection == null) {
      return ListView.builder(
        primary: false,
        itemCount: section.rows.length,
        itemBuilder: (context, index) => rowAt(index),
      );
    }
    return CustomScrollView(
      key: _viewportKey,
      controller: _verticalScroll,
      center: _forwardRows,
      slivers: [
        if (_anchorRow > 0)
          SliverList.builder(
            itemCount: _anchorRow,
            itemBuilder: (context, index) => rowAt(_anchorRow - index - 1),
          ),
        SliverList.builder(
          key: _forwardRows,
          itemCount: section.rows.length - _anchorRow,
          itemBuilder: (context, index) => rowAt(_anchorRow + index),
        ),
      ],
    );
  }

  Widget _row(
    String label,
    Map<int, String> cells,
    AppPalette palette, {
    bool header = false,
    Map<int, List<int>> highlights = const {},
    BulletinXlsMatch? match,
  }) {
    final first = _laidOutColumns?.first ?? 0;
    final end = _laidOutColumns?.end ?? section.columns;
    final leadingSpacer = first > 0;
    final trailingSpacer = end < section.columns;
    return Table(
      defaultColumnWidth: const FixedColumnWidth(_columnWidth),
      columnWidths: {
        0: const FixedColumnWidth(_rowNumberWidth),
        if (leadingSpacer) 1: FixedColumnWidth(_columnWidth * first),
        if (trailingSpacer)
          end - first + (leadingSpacer ? 2 : 1): FixedColumnWidth(
            _columnWidth * (section.columns - end),
          ),
      },
      border: TableBorder(
        left: BorderSide(color: palette.divider),
        right: BorderSide(color: palette.divider),
        bottom: BorderSide(color: palette.divider),
        verticalInside: BorderSide(color: palette.divider),
      ),
      children: [
        TableRow(
          decoration: BoxDecoration(
            color: header ? palette.pageBg : palette.surface,
          ),
          children: [
            _cell(label, palette),
            if (leadingSpacer) const SizedBox.shrink(),
            for (var column = first; column < end; column++)
              _cell(
                header ? _columnName(column) : cells[column] ?? '',
                palette,
                ranges: highlights[column],
                currentStart: match != null && match.column == column
                    ? match.start
                    : null,
              ),
            if (trailingSpacer) const SizedBox.shrink(),
          ],
        ),
      ],
    );
  }

  Widget _cell(
    String text,
    AppPalette palette, {
    List<int>? ranges,
    int? currentStart,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    child: ranges == null
        ? Text(text, style: TextStyle(color: palette.titleText, fontSize: 12))
        : Text.rich(
            key: currentStart == null ? null : _matchTextKey,
            TextSpan(
              children: _highlightedText(text, ranges, palette, currentStart),
            ),
            style: TextStyle(color: palette.titleText, fontSize: 12),
          ),
  );

  List<TextSpan> _highlightedText(
    String text,
    List<int> ranges,
    AppPalette palette,
    int? currentStart,
  ) {
    var start = 0;
    final spans = <TextSpan>[];
    for (var index = 0; index < ranges.length; index += 2) {
      final left = ranges[index];
      final right = ranges[index + 1];
      final current = left == currentStart;
      if (left > start) spans.add(TextSpan(text: text.substring(start, left)));
      spans.add(
        TextSpan(
          text: text.substring(left, right),
          style: TextStyle(
            backgroundColor: current
                ? palette.searchCurrentHighlight
                : palette.searchHighlight,
            color: current
                ? palette.searchCurrentHighlightText
                : palette.searchHighlightText,
            decoration: current ? TextDecoration.underline : null,
          ),
        ),
      );
      start = right;
    }
    if (start < text.length) spans.add(TextSpan(text: text.substring(start)));
    return spans;
  }

  String _columnName(int index) {
    var number = index + 1;
    var label = '';
    while (number > 0) {
      number--;
      label = String.fromCharCode(65 + number % 26) + label;
      number ~/= 26;
    }
    return label;
  }
}
