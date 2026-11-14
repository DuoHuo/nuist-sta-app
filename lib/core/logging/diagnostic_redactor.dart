import 'dart:convert';

/// 保留诊断正文的结构与长度，只替换凭据和个人信息，不裁剪正常内容。
class DiagnosticRedactor {
  DiagnosticRedactor._();

  static const secret = '[REDACTED_SECRET]';
  static const personal = '[REDACTED_PERSONAL]';
  static final _secretKey = RegExp(
    r'^(?:authorization|proxyauthorization|cookie|setcookie|castgc|jsessionid|enssessionid|password|passwd|pwd|pin|ticket|token|accesstoken|refreshtoken|idtoken|synjonesauth|secret|clientsecret|privatekey|privatekeypem|privatekeypkcs8pem|publickeycredential|signature|assertion|attestationobject|authenticatordata|clientdatajson|credentialid|credential|passkey|rawid|anonbiometricsd|execution|csrf|xsrf|ssaid|deviceid|androidid|xclientid|xdeviceid|xclientdeviceid)$',
    caseSensitive: false,
  );
  static final _personalKey = RegExp(
    r'^(?:studentid|studentno|studentnumber|username|account|userid|name|realname|fullname|studentname|teachername|coursename|course|score|grade|gpa|room|roomid|roomno|roomnumber|dorm|dormitory|phone|mobile|email|address|idcard|identitynumber|latitude|longitude|lat|lng|lon|location|query|keyword|search|searchword|searchtext|xh|xm|xsxm|xsmc|jsxm|jsmc|kcmc|cj|zcj|pscj|kscj|jxcj|sfzh|zjh|sjhm|lxdh|学号|姓名|学生姓名|教师姓名|课程名称|课程名|成绩|总评成绩|平时成绩|考试成绩|绩点|宿舍|宿舍号|房间|房间号|手机号|联系电话|身份证号|搜索词|地址)$',
    caseSensitive: false,
  );

  static String _key(String key) => key.replaceAll(RegExp(r'[-_\s]'), '');

  /// 字段名的匹配只用于诊断副本，绝不修改业务请求或响应。
  static String? replacementForKey(String key) {
    final normalized = _key(key);
    if (_secretKey.hasMatch(normalized) ||
        RegExp(
          r'(?:password|privatekey|passkey|secret|token)$',
          caseSensitive: false,
        ).hasMatch(normalized)) {
      return secret;
    }
    if (_personalKey.hasMatch(normalized)) return personal;
    return null;
  }

  /// 递归清洗结构化诊断；保留 null、列表、数字和未知的非敏感字段。
  static Object? value(
    Object? input, {
    String? key,
    bool credentialContext = false,
  }) {
    credentialContext =
        credentialContext ||
        const {
          'allowcredentials',
          'excludecredentials',
        }.contains(key?.toLowerCase());
    if (credentialContext && key?.toLowerCase() == 'id') return secret;
    final replacement = key == null ? null : replacementForKey(key);
    if (replacement != null) {
      return input == null ? null : replacement;
    }
    if (input == null || input is bool) return input;
    if (input is num) return input.isFinite ? input : input.toString();
    if (input is String) {
      if (key == 'body_base64') {
        try {
          final bytes = base64Decode(input);
          // UTF-8 中文不是 ASCII，但仍是必须脱敏的文本；优先严格解码，
          // 不能用 ASCII 字节比例把中文 JSON/HTML 误判为二进制。
          try {
            final decoded = utf8.decode(bytes);
            final controls = decoded.codeUnits
                .where(
                  (unit) =>
                      unit < 32 && unit != 9 && unit != 10 && unit != 13 ||
                      unit == 127,
                )
                .length;
            if (decoded.isEmpty || controls / decoded.length < 0.05) {
              final cleaned = text(
                decoded,
                credentialContext: credentialContext,
              );
              return cleaned == decoded
                  ? input
                  : base64Encode(utf8.encode(cleaned));
            }
          } on FormatException {
            // 非 UTF-8 文本在下面按单字节编码保留和清洗。
          }
          // 二进制附件不做字符串正则替换；看起来是文本的实体仍必须脱敏，
          // 防止损坏编码或嵌套 base64 绕过凭据清洗。
          final printable = bytes
              .where(
                (byte) =>
                    byte >= 32 && byte <= 126 ||
                    byte == 9 ||
                    byte == 10 ||
                    byte == 13,
              )
              .length;
          if (bytes.isEmpty || printable / bytes.length < 0.85) return input;
          final decoded = latin1.decode(bytes);
          final cleaned = text(decoded, credentialContext: credentialContext);
          return cleaned == decoded
              ? input
              : base64Encode(latin1.encode(cleaned));
        } catch (_) {
          return '[INVALID_BASE64]';
        }
      }
      return text(input, credentialContext: credentialContext);
    }
    if (input is Enum) return input.name;
    if (input is Map) {
      credentialContext =
          credentialContext ||
          input.containsKey('rawId') ||
          input['type'] == 'public-key' ||
          _credentialEndpoint(input['url']) ||
          input['request'] is Map &&
              _credentialEndpoint((input['request'] as Map)['url']);
      return <String, Object?>{
        for (final entry in input.entries)
          text(entry.key.toString()):
              key == 'headers' &&
                  entry.key.toString().toLowerCase() == 'location'
              ? value(entry.value)
              : value(
                  entry.value,
                  key: entry.key.toString(),
                  credentialContext: credentialContext,
                ),
      };
    }
    if (input is Iterable) {
      return input
          .map((item) => value(item, credentialContext: credentialContext))
          .toList();
    }
    return text(input.toString());
  }

  /// 保留完整正文和换行。JSON 值按原文区间替换，格式错误时仍保留错误位置附近内容。
  static String text(String input, {bool credentialContext = false}) {
    var output = _redactMultipart(
      _redactHtml(_redactJson(input, credentialContext: credentialContext)),
    );
    if (output.contains('%') || credentialContext) {
      output = _redactEncodedValues(
        output,
        credentialContext: credentialContext,
      );
    }
    output = output.replaceAllMapped(
      RegExp(r'''https?://[^\s<>"']+''', caseSensitive: false),
      (match) => _url(match[0]!),
    );
    output = output.replaceAll(
      RegExp(
        r'-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----',
        caseSensitive: false,
        dotAll: true,
      ),
      secret,
    );
    output = output.replaceAll(
      RegExp(r'\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b'),
      secret,
    );
    output = output.replaceAllMapped(
      RegExp(
        r'(?<=^|\n)[ \t]*(?:(?:proxy-)?authorization|(?:set-)?cookie)\s*[:=][^\r\n]*',
        caseSensitive: false,
      ),
      (match) => '${match[0]!.split(RegExp(r'[:=]')).first}: $secret',
    );
    output = output.replaceAll(
      RegExp(r'\b(?:bearer|basic)\s+[A-Za-z0-9+/=_\-.]+', caseSensitive: false),
      secret,
    );
    // URL、表单和普通异常中的 key=value 保留字段名与分隔符。
    output = _redactAssignments(output);
    // 不改端口、耗时、原生地址；只处理明确的个人编号与联系方式。
    output = output.replaceAll(RegExp(r'(?<!\d)\d{12}(?!\d)'), personal);
    output = output.replaceAll(RegExp(r'(?<!\d)1[3-9]\d{9}(?!\d)'), personal);
    output = output.replaceAll(
      RegExp(r'(?<!\d)\d{17}[\dXx](?![\dA-Za-z])'),
      personal,
    );
    output = output.replaceAll(
      RegExp(
        r'(?<![A-Za-z0-9.!#$%&*+/=?^_`{|}~-])[A-Za-z0-9.!#$%&*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}',
      ),
      personal,
    );
    return output;
  }

  static String _url(String source) {
    // 保留路径和非敏感参数；按原始片段替换，避免编码/参数顺序变化掩盖故障。
    var result = source.replaceFirst(RegExp(r'(?<=://)[^/@]+@'), '$secret@');
    result = result.replaceAllMapped(RegExp(r'([?&#])([^=?&#/]+)=([^&#]*)'), (
      match,
    ) {
      String key;
      String contents;
      try {
        key = Uri.decodeComponent(match[2]!);
        contents = Uri.decodeComponent(match[3]!);
      } catch (_) {
        key = match[2]!;
        contents = match[3]!;
      }
      final replacement = replacementForKey(key);
      if (_isRoutingParameter(source, key, contents)) return match[0]!;
      if (replacement != null) return '${match[1]}${match[2]}=$replacement';
      if (contents.startsWith('http://') || contents.startsWith('https://')) {
        final cleaned = _url(contents);
        if (cleaned == contents) return match[0]!;
        return '${match[1]}${match[2]}=${match[3] == contents ? cleaned : Uri.encodeComponent(cleaned)}';
      }
      return match[0]!;
    });
    return result;
  }

  static String _redactAssignments(String source) {
    final result = StringBuffer();
    final delimiter = RegExp(r'''[\s&;,，；。！？<>"'\[\]{}]''');
    var offset = 0;
    final tags = RegExp(r'<[^>]*>').allMatches(source).toList();
    var tagIndex = 0;
    final urls = RegExp(r'''https?://[^\s<>"']+''').allMatches(source).toList();
    var urlIndex = 0;
    final multipartHeaders = RegExp(
      r'^[ \t]*Content-Disposition:[^\r\n]*',
      multiLine: true,
      caseSensitive: false,
    ).allMatches(source).toList();
    var headerIndex = 0;
    for (final match in RegExp(
      r'(?<![\w\-\u3400-\u9fff])([\w\-\u3400-\u9fff]+)\s*[=:：]\s*',
    ).allMatches(source)) {
      while (urlIndex < urls.length && urls[urlIndex].end <= match.start) {
        urlIndex++;
      }
      if (urlIndex < urls.length && urls[urlIndex].start <= match.start) {
        continue;
      }
      while (headerIndex < multipartHeaders.length &&
          multipartHeaders[headerIndex].end <= match.start) {
        headerIndex++;
      }
      if (headerIndex < multipartHeaders.length &&
          multipartHeaders[headerIndex].start <= match.start) {
        continue;
      }
      while (tagIndex < tags.length && tags[tagIndex].end <= match.start) {
        tagIndex++;
      }
      if (tagIndex < tags.length && tags[tagIndex].start <= match.start) {
        // HTML name/id 描述字段语义，不是个人值；由 _redactHtml 定点清洗。
        continue;
      }
      final replacement = replacementForKey(match[1]!);
      if (replacement == null ||
          match.end < offset ||
          match.end >= source.length) {
        continue;
      }
      final start = match.end;
      if (source.startsWith('[REDACTED_', start)) continue;
      var end = start;
      final quote = source[start] == '"' || source[start] == "'"
          ? source[start]
          : null;
      if (quote != null) {
        end = source.indexOf(quote, start + 1);
        end = end < 0 ? source.length : end + 1;
      } else {
        while (end < source.length && !delimiter.hasMatch(source[end])) {
          end++;
        }
      }
      if (end == start) continue;
      result.write(source.substring(offset, start));
      result.write(quote == null ? replacement : '$quote$replacement$quote');
      offset = end;
    }
    result.write(source.substring(offset));
    return result.toString();
  }

  static bool _credentialEndpoint(Object? value) {
    if (value is! String) return false;
    final path = Uri.tryParse(value)?.path.toLowerCase();
    return const {
      '/authserver/startassertion',
      '/authserver/finishassertion',
      '/authserver/startregister',
      '/authserver/finishregister',
    }.contains(path);
  }

  static String _redactJson(String source, {bool credentialContext = false}) {
    if (source.trimLeft().startsWith('{') &&
        (source.contains('"rawId"') || source.contains('"public-key"'))) {
      try {
        final decoded = jsonDecode(source);
        if (decoded is Map &&
            (decoded.containsKey('rawId') || decoded['type'] == 'public-key')) {
          credentialContext = true;
        }
      } catch (_) {
        // 格式不完整时继续按原文区间清洗。
      }
    }
    // 扫描字符串键和值的原文范围，不要求整份 JSON 有效；坏 JSON 也能脱敏。
    final ranges = <(int, int, String)>[];
    final keys = RegExp(r'"((?:[^"\\]|\\.)*)"\s*:\s*');
    for (final match in keys.allMatches(source)) {
      String key;
      try {
        key = jsonDecode('"${match[1]}"') as String;
      } catch (_) {
        continue;
      }
      final start = match.end;
      if (start >= source.length) continue;
      final end = _valueEnd(source, start);
      if (end <= start) continue;
      final replacement = credentialContext && key.toLowerCase() == 'id'
          ? secret
          : replacementForKey(key);
      if (replacement != null) {
        ranges.add((start, end, jsonEncode(replacement)));
      } else if (const {
        'allowcredentials',
        'excludecredentials',
      }.contains(key.toLowerCase())) {
        try {
          jsonDecode(source.substring(start, end));
          ranges.add((
            start,
            end,
            text(source.substring(start, end), credentialContext: true),
          ));
        } catch (_) {
          ranges.add((start, end, jsonEncode(secret)));
        }
      } else if (source[start] == '"') {
        try {
          final nested = jsonDecode(source.substring(start, end)) as String;
          final cleaned = text(nested, credentialContext: credentialContext);
          if (cleaned != nested) ranges.add((start, end, jsonEncode(cleaned)));
        } catch (_) {
          // 不完整字符串交给正文模式处理，不丢弃其余诊断原文。
        }
      }
    }
    if (ranges.isEmpty) return source;
    final result = StringBuffer();
    var offset = 0;
    for (final (start, end, replacement) in ranges) {
      if (start < offset) continue;
      result.write(source.substring(offset, start));
      result.write(replacement);
      offset = end;
    }
    result.write(source.substring(offset));
    return result.toString();
  }

  static String _redactEncodedValues(
    String source, {
    bool credentialContext = false,
  }) => source.replaceAllMapped(RegExp(r'([?&;]|^)([^=\s&;]+)=([^&\s;]*)'), (
    match,
  ) {
    try {
      final key = Uri.decodeComponent(match[2]!);
      final decoded = Uri.decodeComponent(match[3]!);
      if (_isRoutingParameter(source, key, decoded)) return match[0]!;
      final replacement = credentialContext && key.toLowerCase() == 'id'
          ? secret
          : replacementForKey(key);
      final cleaned =
          replacement ?? text(decoded, credentialContext: credentialContext);
      return cleaned == decoded
          ? match[0]!
          : '${match[1]}${match[2]}=${Uri.encodeComponent(cleaned)}';
    } catch (_) {
      return match[0]!;
    }
  });

  static bool _isRoutingParameter(String source, String key, String value) =>
      key == 'name' &&
      value == 'loginTransit' &&
      Uri.tryParse(source)?.path == '/plat-pc/';

  static int _valueEnd(String source, int start) {
    var inString = false;
    var escaped = false;
    var depth = 0;
    final startsString = source[start] == '"';
    for (var index = start; index < source.length; index++) {
      final character = source[index];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (character == r'\') {
          escaped = true;
        } else if (character == '"') {
          inString = false;
          if (startsString && depth == 0) return index + 1;
        }
        continue;
      }
      if (character == '"') {
        inString = true;
      } else if (character == '{' || character == '[') {
        depth++;
      } else if (character == '}' || character == ']') {
        if (depth == 0) return index;
        if (--depth == 0) return index + 1;
      } else if (depth == 0 &&
          (character == ',' || character == '\n' || character == '\r')) {
        return index;
      }
    }
    return source.length;
  }

  static final _htmlAttributes = RegExp(
    r'''([^\s=<>"']+)(\s*=\s*)(?:"([^"]*)"|'([^']*)'|([^\s>]+))''',
    caseSensitive: false,
  );

  static String _redactMultipart(String source) {
    if (!source.toLowerCase().contains('content-disposition:')) return source;
    return source.replaceAllMapped(
      RegExp(
        r'(^|\r?\n)(Content-Disposition:[^\r\n]*(?:\r?\n(?!\r?\n)[^\r\n]*)*\r?\n\r?\n)(.*?)(?=\r?\n--|$)',
        caseSensitive: false,
        dotAll: true,
      ),
      (match) {
        String? name;
        for (final attribute in _htmlAttributes.allMatches(match[2]!)) {
          if (attribute[1]!.toLowerCase() == 'name') {
            name = attribute[3] ?? attribute[4] ?? attribute[5];
            break;
          }
        }
        final replacement = name == null ? null : replacementForKey(name);
        return replacement == null
            ? match[0]!
            : '${match[1]}${match[2]}$replacement';
      },
    );
  }

  static String _htmlText(String value) => value
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAllMapped(
        RegExp(r'&#(?:x([0-9a-f]+)|(\d+));', caseSensitive: false),
        (m) {
          final code = int.tryParse(
            m[1] ?? m[2]!,
            radix: m[1] == null ? 10 : 16,
          );
          return code == null || code > 0x10ffff
              ? m[0]!
              : String.fromCharCode(code);
        },
      )
      .trim();

  static String? _controlReplacement(String tag) {
    final attributes = {
      for (final match in _htmlAttributes.allMatches(tag))
        match[1]!.toLowerCase(): _htmlText(match[3] ?? match[4] ?? match[5]!),
    };
    if (attributes['type']?.toLowerCase() == 'password') return secret;
    final name = attributes['name'] ?? attributes['id'];
    return name == null ? null : replacementForKey(name);
  }

  static String _redactHtml(String source) {
    if (!source.contains('<')) return source;
    var output = source.replaceAllMapped(
      RegExp(r'<[a-z][^>]*>', caseSensitive: false),
      (match) {
        final tag = match[0]!;
        final control =
            RegExp(r'^<(?:input|meta)\b', caseSensitive: false).hasMatch(tag)
            ? _controlReplacement(tag)
            : null;
        return tag.replaceAllMapped(_htmlAttributes, (attribute) {
          final key = attribute[1]!.toLowerCase();
          // name/id 是页面字段名；只修改对应 value/content 或明确敏感属性。
          if (key == 'name' || key == 'id' || key == 'type') {
            return attribute[0]!;
          }
          final replacement =
              (key == 'value' || key == 'content') && control != null
              ? control
              : replacementForKey(key.replaceFirst(RegExp(r'^data-'), ''));
          if (replacement == null) return attribute[0]!;
          final quote = attribute[3] != null
              ? '"'
              : attribute[4] != null
              ? "'"
              : '';
          return '${attribute[1]}${attribute[2]}$quote$replacement$quote';
        });
      },
    );
    output = output.replaceAllMapped(
      RegExp(
        r'(<textarea\b[^>]*>)(.*?)(</textarea\s*>)',
        caseSensitive: false,
        dotAll: true,
      ),
      (match) {
        final replacement = _controlReplacement(match[1]!);
        return replacement == null
            ? match[0]!
            : '${match[1]}$replacement${match[3]}';
      },
    );
    // 学校页面也会用 td 写表头。只有识别为标题行时才建立列规则；
    // “姓名 / 某人”这种键值行仍清洗同一行的值，不把下一列标题误删。
    const ordinaryHeadings = {
      '状态',
      '序号',
      '编号',
      '类别',
      '类型',
      '操作',
      '说明',
      '备注',
      '日期',
      '时间',
      '学期',
      '学年',
      '学分',
      '课程代码',
      '课程性质',
      '课程类别',
      '学时',
      '教学班',
      '是否通过',
      '项目',
      '项目名称',
      '代码',
      '名称',
      'status',
      'id',
      'type',
      'code',
    };
    final rows = RegExp(
      r'<tr\b[^>]*>.*?</tr\s*>',
      caseSensitive: false,
      dotAll: true,
    );
    final cells = RegExp(
      r'(<t[dh]\b[^>]*>)(.*?)(</t[dh]\s*>)',
      caseSensitive: false,
      dotAll: true,
    );
    return output.replaceAllMapped(
      RegExp(
        r'<table\b[^>]*>.*?</table\s*>',
        caseSensitive: false,
        dotAll: true,
      ),
      (table) {
        final sensitiveColumns = <int, String>{};
        return table[0]!.replaceAllMapped(rows, (row) {
          final matches = cells.allMatches(row[0]!).toList();
          final labels = matches
              .map(
                (cell) => _htmlText(cell[2]!).replaceAll(RegExp(r'[:：]$'), ''),
              )
              .toList();
          final replacements = labels.map(replacementForKey).toList();
          final sensitiveCount = replacements.whereType<String>().length;
          final knownHeadingCells = labels.every(
            (label) =>
                replacementForKey(label) != null ||
                ordinaryHeadings.contains(label.toLowerCase()),
          );
          final adjacentLabels = [
            for (var i = 1; i < replacements.length; i++)
              replacements[i] != null && replacements[i - 1] != null,
          ].contains(true);
          final heading =
              matches.any((cell) => cell[1]!.toLowerCase().startsWith('<th')) ||
              sensitiveCount > 0 && knownHeadingCells ||
              adjacentLabels;
          var column = 0;
          var cellIndex = 0;
          String? pending;
          return row[0]!.replaceAllMapped(cells, (cell) {
            final index = column;
            final spanAttribute = _htmlAttributes
                .allMatches(cell[1]!)
                .where((attribute) => attribute[1]!.toLowerCase() == 'colspan')
                .firstOrNull;
            final span = spanAttribute == null
                ? 1
                : (int.tryParse(
                            spanAttribute[3] ??
                                spanAttribute[4] ??
                                spanAttribute[5]!,
                          ) ??
                          1)
                      .clamp(1, 1000);
            column += span;
            final label = replacements[cellIndex++];
            if (heading) {
              if (label != null) {
                for (var offset = 0; offset < span; offset++) {
                  sensitiveColumns[index + offset] = label;
                }
              }
              return cell[0]!;
            }
            if (label != null) {
              pending = label;
              return cell[0]!;
            }
            final replacement =
                pending ??
                [
                  for (var offset = 0; offset < span; offset++)
                    sensitiveColumns[index + offset],
                ].whereType<String>().firstOrNull;
            pending = null;
            return replacement == null
                ? cell[0]!
                : '${cell[1]}$replacement${cell[3]}';
          });
        });
      },
    );
  }
}
