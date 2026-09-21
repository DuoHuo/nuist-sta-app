/// 从服务端渲染的 HTML 里截取一张表格，按表头文本索引每一行。
///
/// 双创学分（cxxf）与劳动教育（labor）两个系统没有 JSON 接口，数据只在页面
/// 表格里。两边用的是同一套前端框架（`c-table`），结构一致：
/// `<thead>` 一行 `<th>` 是表头，`<tbody>` 每个 `<tr>` 的 `<td>` 按下标对应表头。
/// 这里用正则截取而不引入 HTML 解析库——页面结构固定、字段靠表头名取，够用。
///
/// 已知的坑，都在这里处理：
/// - 单元格里塞了自定义元素 `<td-data data-name=… data-value=…>`，标签正则
///   必须写成 `<td(?:\s…)?>`，否则 `<td-data` 会被当成单元格起始；
/// - 属性值里可能出现 `>`（如 `data-responsive--bind-click="td>span.c-link"`），
///   所以标签匹配要认引号；但引号也可能多出一个孤立的（劳动成绩表的复选框
///   表头），认引号只能是「优先」，配不上得能退回，见 [_attrs]；
/// - 隐藏列（复选框、「专业劳动」「自证材料积分」）表头和单元格同时存在，
///   下标天然对齐，不需要也不应该跳过；
/// - 空表时 `<tbody>` 只有一行 `<th colspan>暂无数据</th>`，没有 `<td>`，跳过即可。
library;

/// 解析 id 为 [tableId] 的表格，返回每行「表头文本 → 单元格文本」。
///
/// 找不到该表格返回 null（调用方据此判断是否被弹回了登录页）；表格存在但
/// 没有数据行返回空列表。单元格文本已去标签、解实体、折叠空白。
List<Map<String, String>>? parseHtmlTable(String html, String tableId) {
  final table = _sliceTable(html, tableId);
  if (table == null) return null;

  final headers = [
    for (final m in _cells('th').allMatches(_section(table, 'thead') ?? ''))
      cleanHtmlText(m.group(1)!),
  ];
  final body = _section(table, 'tbody') ?? table;
  final rows = <Map<String, String>>[];
  for (final tr in _rowPattern.allMatches(body)) {
    final cells = [
      for (final m in _cells('td').allMatches(tr.group(1)!))
        cleanHtmlText(m.group(1)!),
    ];
    if (cells.isEmpty) continue;
    rows.add({
      for (var i = 0; i < cells.length && i < headers.length; i++)
        if (headers[i].isNotEmpty) headers[i]: cells[i],
    });
  }
  return rows;
}

/// 去标签、解常见实体、把连续空白折叠成一个空格。
String cleanHtmlText(String fragment) => fragment
    .replaceAll(_anyTag, ' ')
    .replaceAllMapped(
      RegExp(r'&#x([0-9a-fA-F]+);'),
      (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
    )
    .replaceAllMapped(
      RegExp(r'&#(\d+);'),
      (m) => String.fromCharCode(int.parse(m.group(1)!)),
    )
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&quot;', '"')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

// ==================== 内部实现 ====================

/// 标签内属性部分。优先按引号配对（引号里允许出现 `>`）；页面里也见过
/// `class="x" " data-y="1"` 这种多出一个孤立引号的写法，配对会一路吞到下一个
/// 标签去，所以引号里不许有 `<`，配不上就退回「到第一个 `>` 为止」。
const _attrs = '''(?:(?:[^>"']|"[^"<]*"|'[^'<]*')*|[^>]*)''';

final _anyTag = RegExp('<[^\\s>]*$_attrs>', dotAll: true);

final _rowPattern = RegExp('<tr(?:\\s$_attrs)?>(.*?)</tr>', dotAll: true);

/// `<td>` / `<th>` 的匹配。`(?:\s…)?` 保证 `<td-data` 不会被误认。
RegExp _cells(String tag) =>
    RegExp('<$tag(?:\\s$_attrs)?>(.*?)</$tag>', dotAll: true);

/// 取出 `<table … id="tableId" …>` 到最近的 `</table>` 之间的内容。
String? _sliceTable(String html, String tableId) {
  final open = RegExp(
    '<table(?:\\s$_attrs)?\\sid=["\']${RegExp.escape(tableId)}["\']$_attrs>',
    dotAll: true,
  ).firstMatch(html);
  if (open == null) return null;
  final close = html.indexOf('</table>', open.end);
  return html.substring(open.end, close < 0 ? html.length : close);
}

String? _section(String table, String tag) => RegExp(
  '<$tag(?:\\s$_attrs)?>(.*?)</$tag>',
  dotAll: true,
).firstMatch(table)?.group(1);
