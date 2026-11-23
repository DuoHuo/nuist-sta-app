import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../core/colors.dart';
import '../../core/ui/miuix_dialog.dart';
import 'bulletin_attachment_preview.dart';

const _channel = MethodChannel('dev.duohuo.nuist_sta_app/attachment_pdf');

/// 附件搜索用黄色标记普通命中，用红色突出当前命中。
extension BulletinSearchPalette on AppPalette {
  Color get searchHighlight =>
      isDark ? const Color(0xFFFFEF00) : const Color(0xFFFFE500);

  Color get searchCurrentHighlight =>
      isDark ? const Color(0xFFD21E39) : const Color(0xFFC31932);

  Color get searchHighlightText => AppPalette.light.titleText;

  Color get searchCurrentHighlightText => AppPalette.light.surface;
}

/// 合并短时间内的键入，只展示最新关键词和大小写选项的结果。
class BulletinLiveSearch<T> extends ChangeNotifier {
  BulletinLiveSearch(this._find, this._countMatches);

  final Future<T> Function(String text, bool matchCase) _find;
  final int Function(T result) _countMatches;
  Timer? _timer;
  int _revision = 0;
  int _selectedIndex = 0;
  String _query = '';
  bool matchCase = false;
  bool busy = false;
  bool failed = false;
  T? result;

  bool get active => _query.trim().isNotEmpty;
  int get selectedIndex => _selectedIndex;

  int get count {
    final matches = result;
    return matches == null ? 0 : _countMatches(matches);
  }

  void move(int offset) {
    final total = count;
    if (total > 1) jumpTo((_selectedIndex + offset) % total);
  }

  void jumpTo(int index) {
    if (index < 0 || index >= count) return;
    _selectedIndex = index;
    notifyListeners();
  }

  void updateText(String value) {
    _query = value;
    _schedule();
  }

  void updateMatchCase(bool value) {
    matchCase = value;
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    final revision = ++_revision;
    _selectedIndex = 0;
    result = null;
    failed = false;
    busy = active;
    if (active) {
      _timer = Timer(const Duration(milliseconds: 150), () {
        unawaited(_lookup(revision, _query, matchCase));
      });
    } else {
      unawaited(_cancel());
    }
    notifyListeners();
  }

  Future<void> _lookup(int revision, String query, bool caseSensitive) async {
    try {
      final value = await _find(query, caseSensitive);
      if (revision != _revision) return;
      result = value;
    } catch (_) {
      if (revision != _revision) return;
      failed = true;
    }
    busy = false;
    notifyListeners();
  }

  Future<void> _cancel({bool release = false}) async {
    try {
      await _channel.invokeMethod<void>('cancelSearch', {'release': release});
    } catch (_) {
      // 页面退出时平台通道可能已经释放。
    }
  }

  @override
  void dispose() {
    ++_revision;
    _timer?.cancel();
    unawaited(_cancel(release: true));
    super.dispose();
  }
}

/// 一个 PDF 命中可能跨行，坐标以页面左上角为原点，按页宽、页高归一化。
typedef BulletinPdfMatch = ({int page, List<Rect> rects});

Future<List<BulletinPdfMatch>> findBulletinPdfText(
  File file,
  String query,
  bool matchCase,
) async {
  final matches = await _channel.invokeListMethod<dynamic>('searchPdf', {
    'path': file.path,
    'query': query,
    'matchCase': matchCase,
  });
  return [
    for (final match in matches ?? const [])
      (
        page: match['page'] as int,
        rects: _rects((match['rects'] as List).cast<double>()),
      ),
  ];
}

List<Rect> _rects(List<double> coordinates) => [
  for (var i = 0; i < coordinates.length; i += 4)
    Rect.fromLTRB(
      coordinates[i],
      coordinates[i + 1],
      coordinates[i + 2],
      coordinates[i + 3],
    ),
];

/// Excel 的单个命中，行下标对应搜索结果里的行，文字范围以 UTF-16 计数。
typedef BulletinXlsMatch = ({
  int sheet,
  int row,
  int column,
  int start,
  int end,
});

/// 工作簿搜索结果，命中按工作表、行、列和单元格内的位置排列。
typedef BulletinXlsMatches = ({
  List<BulletinXlsMatch> matches,
  List<BulletinOfficeSection> sheets,
});

Future<BulletinXlsMatches> findBulletinXlsText(
  File file,
  String query,
  bool matchCase,
) async {
  final sheets = await _channel.invokeListMethod<dynamic>('searchXls', {
    'path': file.path,
    'query': query,
    'matchCase': matchCase,
  });
  final sections = [
    for (final sheet in sheets ?? const [])
      BulletinOfficeSection.fromData(sheet as Map),
  ];
  final matches = <BulletinXlsMatch>[];
  for (final (sheetIndex, sheet) in sections.indexed) {
    for (final (rowIndex, row) in sheet.rows.indexed) {
      final columns = row.highlights.keys.toList()..sort();
      for (final column in columns) {
        final ranges = row.highlights[column]!;
        for (var i = 0; i < ranges.length; i += 2) {
          matches.add((
            sheet: sheetIndex,
            row: rowIndex,
            column: column,
            start: ranges[i],
            end: ranges[i + 1],
          ));
        }
      }
    }
  }
  return (matches: matches, sheets: sections);
}

/// 输入结果序号并跳转的弹窗内容。
class _JumpToResultContent extends StatefulWidget {
  const _JumpToResultContent({required this.count, required this.onClose});

  final int count;
  final ValueChanged<int?> onClose;

  @override
  State<_JumpToResultContent> createState() => _JumpToResultContentState();
}

class _JumpToResultContentState extends State<_JumpToResultContent> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final number = int.tryParse(_controller.text.trim());
    if (number == null || number < 1 || number > widget.count) {
      setState(() => _error = '请输入 1 到 ${widget.count} 之间的序号');
      return;
    }
    widget.onClose(number - 1);
  }

  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    final primary = MiuixButtonDefaults.buttonColorsPrimary(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MiuixTextField(
          controller: _controller,
          autofocus: true,
          singleLine: true,
          keyboardType: TextInputType.number,
          label: '结果序号',
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          onSubmitted: (_) => _submit(),
        ),
        if (_error case final message?)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              message,
              style: theme.textStyles.body2.copyWith(color: theme.colors.error),
            ),
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: MiuixButton(
                colors: primary,
                onPressed: () => widget.onClose(null),
                child: const Text('取消'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: MiuixButton(onPressed: _submit, child: const Text('跳转')),
            ),
          ],
        ),
      ],
    );
  }
}

/// 附件预览顶部的实时搜索框、命中数和匹配选项。
class BulletinSearchField extends StatelessWidget {
  const BulletinSearchField({
    super.key,
    required this.search,
    this.showMatchCase = true,
  });

  final BulletinLiveSearch<dynamic> search;

  /// 查找引擎不支持区分大小写时隐藏该选项。
  final bool showMatchCase;

  Future<void> _promptJump(BuildContext context) async {
    final result = search.result;
    final count = search.count;
    final index = await showMiuixDialog<int>(
      context,
      title: '跳转到搜索结果',
      centered: true,
      builder: (dialogContext, dialog) =>
          _JumpToResultContent(count: count, onClose: dialog.close),
    );
    if (context.mounted && index != null && identical(search.result, result)) {
      search.jumpTo(index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final count = search.count;
    final current = count == 0 ? 0 : search.selectedIndex + 1;
    final status = search.failed
        ? '无法查找附件中的文字'
        : search.busy
        ? '正在查找…'
        : '共找到 $count 项';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            autofocus: true,
            onChanged: search.updateText,
            decoration: InputDecoration(
              labelText: '查找文字',
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '上一项',
                    onPressed: count > 1 ? () => search.move(-1) : null,
                    icon: const Icon(Icons.keyboard_arrow_up),
                  ),
                  Tooltip(
                    message: '输入结果序号',
                    child: TextButton(
                      onPressed: count == 0 ? null : () => _promptJump(context),
                      child: Text('$current/$count'),
                    ),
                  ),
                  IconButton(
                    tooltip: '下一项',
                    onPressed: count > 1 ? () => search.move(1) : null,
                    icon: const Icon(Icons.keyboard_arrow_down),
                  ),
                ],
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    status,
                    style: TextStyle(color: palette.labelText),
                  ),
                ),
              ),
              if (showMatchCase) ...[
                Checkbox(
                  value: search.matchCase,
                  onChanged: (value) => search.updateMatchCase(value ?? false),
                  semanticLabel: '大小写敏感',
                ),
                GestureDetector(
                  onTap: () => search.updateMatchCase(!search.matchCase),
                  child: const Text('大小写敏感'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
