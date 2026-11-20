import 'dart:convert';

/// 校方目录支持的检索字段。
enum LibrarySearchField {
  keyword('关键词', 'all', '*'),
  title('书名', 'titles', '*'),
  author('作者', 'authors', '*'),
  isbn('ISBN', 'isbns', '=');

  const LibrarySearchField(this.label, this.field, this.operator);

  final String label;
  final String field;
  final String operator;
}

/// 一页带总数的馆藏或借阅记录。
class LibraryResultPage<T> {
  const LibraryResultPage({required this.items, required this.total});

  final List<T> items;
  final int total;
}

/// 馆藏检索返回的书目摘要。
class LibraryBook {
  LibraryBook.fromJson(Map<String, dynamic> json)
    : id = _text(json['bibId']),
      title = _text(json['title']),
      author = _text(json['author']),
      publisher = _text(json['publisher']),
      publicationYear = _text(json['pub_year']),
      callNumber = _text(json['callno']),
      copyCount = _integer(json['itemCount']),
      availableCount = _integer(json['circCount']);

  final String id;
  final String title;
  final String author;
  final String publisher;
  final String publicationYear;
  final String callNumber;
  final int? copyCount;
  final int? availableCount;
}

/// 书目卡所需的公开编目信息。
class LibraryBookInfo {
  const LibraryBookInfo._({
    required this.fields,
    required this.title,
    required this.author,
    required this.isbns,
    required this.price,
    required this.isbnNotes,
  });

  factory LibraryBookInfo.fromJson(Map<String, dynamic> json) {
    final fields = <String, String>{};
    for (final entry in _infoMap(json, 'detailInfo').entries) {
      final text = _bookFieldText(entry.value);
      if (text.isNotEmpty) fields[entry.key] = text;
    }
    final base = _infoMap(json, 'baseInfo');
    final statement = fields['题名/责任者'] ?? '';
    final baseTitle = _bookFieldText(base['title']);
    final statementSeparator = baseTitle.isEmpty
        ? statement.lastIndexOf(RegExp(r'[/／]'))
        : (statement.startsWith('$baseTitle/') ||
                  statement.startsWith('$baseTitle／')
              ? baseTitle.length
              : -1);
    final title = baseTitle.isNotEmpty
        ? baseTitle
        : statementSeparator < 0
        ? statement
        : statement.substring(0, statementSeparator).trim();
    final author =
        [
              _bookFieldText(base['author']),
              if (statementSeparator >= 0)
                statement.substring(statementSeparator + 1).trim(),
              fields['个人责任者'] ?? '',
            ]
            .map((value) => value.replaceAll(_authorRole, '').trim())
            .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    final isbnAndPrice = fields['ISBN及定价'] ?? '';
    final isbns = <String, String>{};
    for (final source in [
      _bookFieldText(base['isbn']),
      fields['ISBN'] ?? '',
      isbnAndPrice,
    ]) {
      for (final match in _isbnPattern.allMatches(source)) {
        final isbn = match[0]!.replaceAll(' ', '').toUpperCase();
        isbns.putIfAbsent(isbn.replaceAll('-', ''), () => isbn);
      }
    }
    final prices = _pricePattern.allMatches(isbnAndPrice).map((match) {
      final currency = match[1]?.toUpperCase();
      final amount = match[2] ?? match[3]!;
      return switch (currency) {
        null || 'CNY' || 'RMB' || '¥' || '￥' => '¥ $amount',
        _ => '$currency $amount',
      };
    }).toSet();
    final isbnNotes = isbnAndPrice
        .replaceAll(_isbnPattern, '')
        .replaceAll(_pricePattern, '')
        .replaceAll(RegExp(r'^[\s/／,，;；、]+|[\s/／,，;；、]+$'), '');
    return LibraryBookInfo._(
      fields: Map.unmodifiable(fields),
      title: title,
      author: author,
      isbns: List.unmodifiable(isbns.values),
      price: fields['图书定价'] ?? fields['定价'] ?? prices.join(' / '),
      isbnNotes: isbnNotes,
    );
  }

  final Map<String, String> fields;
  final String title;
  final String author;
  final List<String> isbns;
  final String price;
  final String isbnNotes;

  /// 仅保留明确标注的页数，略去罗马数字前页、插图、开本等信息。
  String? get pageCount {
    final extent = fields['载体形态项'] ?? fields['载体形态'] ?? '';
    final count = fields['页数'] ?? '';
    final pages =
        _pageCountPattern.firstMatch(extent)?.group(1) ??
        _pageCountPattern.firstMatch(count)?.group(1) ??
        _pageDigitsPattern.stringMatch(count);
    if (pages == null) return null;
    final digits = pages.codeUnits.map(
      (unit) => unit >= 0xFF10 && unit <= 0xFF19 ? unit - 0xFEE0 : unit,
    );
    return '${String.fromCharCodes(digits)}页';
  }

  /// 兼容缺少详情字段，但仍返回基本书目的记录。
  bool get hasDetails =>
      fields.isNotEmpty ||
      title.isNotEmpty ||
      author.isNotEmpty ||
      isbns.isNotEmpty;
}

/// 单条馆藏副本的位置和流通状态。
class LibraryHolding {
  LibraryHolding.fromJson(Map<String, dynamic> json)
    : library = _text(json['library']),
      location = _text(json['locationName']).isNotEmpty
          ? _text(json['locationName'])
          : _text(json['location']),
      callNumber = _text(json['callNo']),
      shelfMark = _text(json['shelfMark']),
      status = _text(json['status']);

  final String library;
  final String location;
  final String callNumber;
  final String shelfMark;
  final String status;
}

/// 校方「当前借阅」中的一条记录。
class LibraryLoan {
  LibraryLoan.fromJson(Map<String, dynamic> json)
    : bookId = _text(json['bibId']),
      title = _text(_mapOrEmpty(json['bibAttrs'])['title']),
      author = _text(_mapOrEmpty(json['bibAttrs'])['author']),
      location = _text(json['location']),
      borrowedOn = _calendarDate(json['loanDate']),
      dueOn = _calendarDate(json['dueDate']),
      status = switch (json['loanStatus']) {
        'overdue' => '已逾期',
        'soon' => '即将到期',
        _ => '',
      };

  final String bookId;
  final String title;
  final String author;
  final String location;
  final String borrowedOn;
  final String dueOn;
  final String status;
}

/// 解析校方成功响应，错误码、无效响应与正常空列表分别处理。
Map<String, dynamic> libraryResponseData(Object? body) {
  final json = _requiredMap(body is String ? jsonDecode(body) : body);
  if (_integer(json['code']) != 0) {
    throw const FormatException('图书馆接口返回失败状态');
  }
  return _requiredMap(json['data']);
}

/// 解析一页记录，避免把未返回列表的响应当成空结果。
LibraryResultPage<T> libraryResultPage<T>(
  Map<String, dynamic> data,
  String listKey,
  T Function(Map<String, dynamic>) fromJson,
) {
  final total = _integer(data['total']);
  final items = data[listKey];
  if (total == null || total < 0 || items is! List) {
    throw const FormatException('图书馆分页响应格式有误');
  }
  return LibraryResultPage(
    items: List.unmodifiable(items.map((item) => fromJson(_requiredMap(item)))),
    total: total,
  );
}

/// 馆藏接口现行版本将副本数组作为一个 JSON 字符串返回。
List<LibraryHolding> libraryHoldings(Map<String, dynamic> data) {
  final holdings = data['holdings'];
  final items = holdings is String ? jsonDecode(holdings) : holdings;
  if (items is! List) {
    throw const FormatException('馆藏副本响应格式有误');
  }
  return List.unmodifiable(
    items.map((item) => LibraryHolding.fromJson(_requiredMap(item))),
  );
}

Map<String, dynamic> _infoMap(Map<String, dynamic> json, String key) =>
    _mapOrEmpty(_mapOrEmpty(_requiredMap(json['map'])[key])['map']);

Map<String, dynamic> _requiredMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  throw const FormatException('图书馆响应格式有误');
}

Map<String, dynamic> _mapOrEmpty(Object? value) =>
    value is Map<String, dynamic> ? value : const {};

String _text(Object? value) => switch (value) {
  String() => value.trim(),
  num() => value.toString(),
  List() => value.map(_text).where((part) => part.isNotEmpty).join('、'),
  _ => '',
};

final _isbnPattern = RegExp(
  r'(?<![0-9-])(?:97[89][ -]?)?(?:[0-9][ -]?){9}[0-9Xx](?![0-9-])',
);
final _pricePattern = RegExp(
  r'(CNY|RMB|HKD|USD|EUR|GBP|JPY|TWD|NTD|[¥￥])\s*([0-9]+(?:\.[0-9]+)?)|([0-9]+(?:\.[0-9]+)?)\s*元',
  caseSensitive: false,
);
final _pageCountPattern = RegExp(
  r'([0-9０-９]+)\s*(?:[页頁](?!\s*[图圖]版)|pages?\b|pp?\b)',
  caseSensitive: false,
);
final _pageDigitsPattern = RegExp(r'^[0-9０-９]+$');
final _authorRole = RegExp(r'\s*(?:主编|编译|撰著|著|编|译)(?=\s*[,，、;；]|$)');
final _catalogueLineBreak = RegExp(
  r'<br\s*/?>|</(?:p|div|li)\s*>',
  caseSensitive: false,
);
final _catalogueTags = RegExp(
  r"""<!--[\s\S]*?-->|</?[a-zA-Z][a-zA-Z0-9:-]*(?=[\s/>])(?:"[^"]*"|'[^']*'|[^'"<>])*?>""",
);
final _catalogueEntities = RegExp(
  r'&(#(?:[xX][0-9a-fA-F]+|[0-9]+)|[a-zA-Z]+);',
);
const _catalogueEntityText = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
  'ensp': ' ',
  'emsp': ' ',
  'middot': '·',
  'ndash': '–',
  'mdash': '—',
  'hellip': '…',
  'ldquo': '“',
  'rdquo': '”',
  'lsquo': '‘',
  'rsquo': '’',
};

// 出版社、作者等字段带有校方站内搜索链接，只保留用户看到的文字。
String _bookFieldText(Object? value) {
  if (value is List) {
    return value.map(_bookFieldText).where((part) => part.isNotEmpty).join('、');
  }
  return _text(value)
      .replaceAll(_catalogueLineBreak, '\n')
      .replaceAll(_catalogueTags, '')
      .replaceAllMapped(_catalogueEntities, _decodeCatalogueEntity)
      .replaceAll('编著', '')
      .replaceAll(RegExp(r'[^\S\n]+'), ' ')
      .replaceAll(RegExp(r' *\n+ *'), '\n')
      .trim();
}

String _decodeCatalogueEntity(Match match) {
  final name = match[1]!;
  if (!name.startsWith('#')) return _catalogueEntityText[name] ?? match[0]!;
  final hex = name.startsWith('#x') || name.startsWith('#X');
  final code = int.tryParse(name.substring(hex ? 2 : 1), radix: hex ? 16 : 10);
  if (code == null ||
      code <= 0 ||
      code > 0x10ffff ||
      (code >= 0xd800 && code <= 0xdfff)) {
    return match[0]!;
  }
  return String.fromCharCode(code);
}

int? _integer(Object? value) => switch (value) {
  int() => value,
  String() => int.tryParse(value),
  _ => null,
};

String _calendarDate(Object? value) {
  final text = _text(value);
  return RegExp(r'^\d{4}-\d{2}-\d{2}').stringMatch(text) ?? text;
}
