import 'announcement_models.dart';

/// 将公告详情 HTML 解析为适合 Flutter 原生渲染的正文和附件。
AnnouncementDetailDocument? parseAnnouncementDetail(
  String html, {
  required Uri currentUri,
}) {
  if (html.trim().isEmpty) return null;

  final document = _HtmlParser(html).parse();
  final allText = _cleanText(_nodeText(document));
  if (_looksLikeRestrictedPage(allText)) return null;

  final content = _findContentNode(document);
  final attachments = _collectAttachments(content, currentUri);
  final blocks = _extractBlocks(content, currentUri);
  if (blocks.isEmpty && attachments.isEmpty) return null;

  return AnnouncementDetailDocument(
    blocks: List.unmodifiable(blocks),
    attachments: List.unmodifiable(attachments),
  );
}

bool _looksLikeRestrictedPage(String text) {
  if (text.contains('该信息仅允许校内地址访问')) return true;
  if (text.contains('仅允许校内地址访问')) return true;
  if (text.contains('请通过 VPN') || text.contains('请通过vpn')) return true;
  return text.length < 300 &&
      (text.contains('统一身份认证') || text.contains('登录后访问'));
}

_HtmlNode _findContentNode(_HtmlNode root) {
  final candidates = <_ContentCandidate>[];
  var order = 0;
  for (final node in _elements(root)) {
    final name =
        '${node.attributes['id'] ?? ''} '
                '${node.attributes['class'] ?? ''}'
            .toLowerCase();
    var score = 0;
    if (name.contains('vsb_content')) score += 120;
    if (name.contains('wp_articlecontent')) score += 115;
    if (name.contains('article-content') || name.contains('article_content')) {
      score += 105;
    }
    if (name.contains('articlebody') || name.contains('article-body')) {
      score += 100;
    }
    if (name.contains('content')) score += 45;
    if (name.contains('article')) score += 35;
    if (name.contains('detail') || name.contains('main')) score += 20;
    if (['header', 'footer', 'nav', 'menu', 'sidebar'].any(name.contains)) {
      score -= 100;
    }
    if (score > 0) candidates.add(_ContentCandidate(score, order, node));
    order++;
  }
  if (candidates.isEmpty) return root;
  candidates.sort((a, b) {
    final score = b.score.compareTo(a.score);
    return score == 0 ? a.order.compareTo(b.order) : score;
  });
  return candidates.first.node;
}

List<AnnouncementAttachment> _collectAttachments(
  _HtmlNode content,
  Uri currentUri,
) {
  final attachments = <AnnouncementAttachment>[];
  final seen = <String>{};
  for (final node in _elements(content)) {
    if (node.tag != 'a') continue;
    final url = _resolveUrl(node.attributes['href'], currentUri);
    if (url == null || !_isAttachmentLink(node, url)) continue;
    if (!seen.add(url)) continue;
    final label = _cleanText(_nodeText(node));
    attachments.add(
      AnnouncementAttachment(name: _attachmentName(label, url), url: url),
    );
  }
  return attachments;
}

String _attachmentName(String label, String url) {
  if (label.isNotEmpty) return label;
  final pathSegments = Uri.tryParse(url)?.pathSegments;
  final path = pathSegments == null || pathSegments.isEmpty
      ? null
      : pathSegments.last;
  return path == null || path.isEmpty ? '公告附件' : Uri.decodeComponent(path);
}

bool _isAttachmentLink(_HtmlNode node, String url) {
  final label = _nodeText(node).replaceAll(RegExp(r'\s+'), '').toLowerCase();
  final metadata =
      '${node.attributes['class'] ?? ''} '
              '${node.attributes['id'] ?? ''}'
          .toLowerCase();
  if (metadata.contains('attachment') || metadata.contains('download')) {
    return true;
  }
  if (label.contains('附件') || label.contains('下载') || label.contains('查看附件')) {
    return true;
  }
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
  return RegExp(r'\.(pdf|docx?|xlsx?|pptx?|zip|rar|7z|txt|wps|jpg|jpeg|png)$')
      .hasMatch(path);
}

String? _resolveUrl(String? raw, Uri base) {
  if (raw == null || raw.trim().isEmpty) return null;
  final value = _decodeEntities(raw.trim());
  if (value.startsWith('#') || value.startsWith('javascript:')) return null;
  final resolved = base.resolve(value);
  if (!['http', 'https'].contains(resolved.scheme)) return null;
  return resolved.toString();
}

List<AnnouncementDetailBlock> _extractBlocks(_HtmlNode root, Uri currentUri) {
  final blocks = <AnnouncementDetailBlock>[];

  void visit(_HtmlNode node) {
    if (node.isText || _isHidden(node)) return;
    final tag = node.tag;
    if ({'h1', 'h2', 'h3', 'h4', 'h5', 'h6'}.contains(tag)) {
      final text = _cleanText(_nodeText(node, currentUri: currentUri));
      if (text.isNotEmpty) {
        blocks.add(
          AnnouncementDetailBlock(
            kind: AnnouncementDetailBlockKind.heading,
            text: text,
            level: int.tryParse(tag.substring(1)) ?? 2,
            centered: _isCentered(node),
          ),
        );
      }
      return;
    }
    if (tag == 'img') {
      final url = _resolveUrl(node.attributes['src'], currentUri);
      if (url != null) {
        blocks.add(
          AnnouncementDetailBlock(
            kind: AnnouncementDetailBlockKind.image,
            url: url,
            altText: _decodeEntities(node.attributes['alt'] ?? '').trim(),
            centered: _isCentered(node),
          ),
        );
      }
      return;
    }
    if (tag == 'ul' || tag == 'ol') {
      final items = [
        for (final child in node.children.where((child) => child.tag == 'li'))
          _cleanText(_nodeText(child, currentUri: currentUri)),
      ].where((item) => item.isNotEmpty).toList();
      if (items.isNotEmpty) {
        blocks.add(
          AnnouncementDetailBlock(
            kind: tag == 'ul'
                ? AnnouncementDetailBlockKind.bulletList
                : AnnouncementDetailBlockKind.numberedList,
            items: items,
          ),
        );
      }
      return;
    }
    if (tag == 'blockquote') {
      final text = _cleanText(_nodeText(node, currentUri: currentUri));
      if (text.isNotEmpty) {
        blocks.add(
          AnnouncementDetailBlock(
            kind: AnnouncementDetailBlockKind.quote,
            text: text,
          ),
        );
      }
      return;
    }
    if (tag == 'table') {
      final rows = <String>[];
      for (final row in _descendants(node, 'tr')) {
        final cells = [
          for (final cell in row.children.where(
            (child) => child.tag == 'td' || child.tag == 'th',
          ))
            _cleanText(_nodeText(cell, currentUri: currentUri)),
        ].where((cell) => cell.isNotEmpty).toList();
        if (cells.isNotEmpty) rows.add(cells.join('  ·  '));
      }
      if (rows.isNotEmpty) {
        blocks.add(
          AnnouncementDetailBlock(
            kind: AnnouncementDetailBlockKind.table,
            items: rows,
          ),
        );
      }
      return;
    }

    if (_isBlockTag(tag)) {
      final hasBlockChild = node.children.any(
        (child) =>
            !child.isText && (_isBlockTag(child.tag) || child.tag == 'img'),
      );
      if (!hasBlockChild) {
        final text = _cleanText(_nodeText(node, currentUri: currentUri));
        if (text.isNotEmpty) {
          blocks.add(
            AnnouncementDetailBlock(
              kind: AnnouncementDetailBlockKind.paragraph,
              text: text,
              centered: _isCentered(node),
            ),
          );
        }
        return;
      }
    }
    for (final child in node.children) {
      visit(child);
    }
  }

  visit(root);
  return blocks;
}

bool _isBlockTag(String tag) => {
  'address',
  'article',
  'body',
  'caption',
  'dd',
  'div',
  'dl',
  'dt',
  'figcaption',
  'figure',
  'footer',
  'form',
  'header',
  'hr',
  'li',
  'main',
  'nav',
  'ol',
  'p',
  'pre',
  'section',
  'table',
  'td',
  'th',
  'tr',
  'ul',
}.contains(tag);

bool _isHidden(_HtmlNode node) =>
    node.tag == 'script' ||
    node.tag == 'style' ||
    node.tag == 'noscript' ||
    node.tag == 'nav' ||
    node.tag == 'footer' ||
    (node.attributes['aria-hidden'] ?? '').toLowerCase() == 'true' ||
    (node.attributes['style'] ?? '').toLowerCase().contains('display:none');

bool _isCentered(_HtmlNode node) {
  final align =
      '${node.attributes['align'] ?? ''} '
              '${node.attributes['style'] ?? ''}'
          .toLowerCase();
  return align.contains('center');
}

String _nodeText(_HtmlNode node, {Uri? currentUri}) {
  if (node.isText) return _decodeEntities(node.text ?? '');
  if (_isHidden(node)) return '';
  if (node.tag == 'br') return '\n';
  if (node.tag == 'img') return '';
  if (node.tag == 'a' && currentUri != null) {
    final url = _resolveUrl(node.attributes['href'], currentUri);
    if (url != null && _isAttachmentLink(node, url)) return '';
  }
  final parts = [
    for (final child in node.children) _nodeText(child, currentUri: currentUri),
  ];
  return parts.join();
}

String _cleanText(String text) => text
    .replaceAll(RegExp(r'[ \t\r\f]+'), ' ')
    .replaceAll(RegExp(r'\n[ \t]+'), '\n')
    .replaceAll(RegExp(r'\n{3,}'), '\n\n')
    .trim();

Iterable<_HtmlNode> _elements(_HtmlNode root) sync* {
  if (!root.isText) yield root;
  for (final child in root.children) {
    yield* _elements(child);
  }
}

Iterable<_HtmlNode> _descendants(_HtmlNode root, String tag) sync* {
  for (final child in root.children) {
    if (child.tag == tag) yield child;
    yield* _descendants(child, tag);
  }
}

class _ContentCandidate {
  const _ContentCandidate(this.score, this.order, this.node);

  final int score;
  final int order;
  final _HtmlNode node;
}

class _HtmlNode {
  _HtmlNode.element(this.tag, this.attributes) : text = null;
  _HtmlNode.text(this.text) : tag = '', attributes = const {};

  final String tag;
  final Map<String, String> attributes;
  final List<_HtmlNode> children = [];
  final String? text;

  bool get isText => tag.isEmpty;
}

class _HtmlParser {
  _HtmlParser(this.html);

  final String html;

  _HtmlNode parse() {
    final root = _HtmlNode.element('document', const {});
    final stack = <_HtmlNode>[root];
    final tokenPattern = RegExp(r'<!--[\s\S]*?-->|<![^>]*>|<[^>]+>|[^<]+');
    for (final match in tokenPattern.allMatches(html)) {
      final token = match.group(0)!;
      if (token.startsWith('<!--') || token.startsWith('<!')) continue;
      if (token.startsWith('</')) {
        final closing = RegExp(
          r'</\s*([\w:-]+)',
          caseSensitive: false,
        ).firstMatch(token)?.group(1)?.toLowerCase();
        if (closing == null) continue;
        for (var index = stack.length - 1; index > 0; index--) {
          if (stack[index].tag == closing) {
            stack.removeRange(index, stack.length);
            break;
          }
        }
        continue;
      }
      if (token.startsWith('<')) {
        final opening = RegExp(
          r'<\s*([\w:-]+)([\s\S]*?)(/?)>',
          caseSensitive: false,
        ).firstMatch(token);
        if (opening == null) continue;
        final tag = opening.group(1)!.toLowerCase();
        final node = _HtmlNode.element(
          tag,
          _parseAttributes(opening.group(2) ?? ''),
        );
        stack.last.children.add(node);
        if (!_voidTags.contains(tag) && opening.group(3) != '/') {
          stack.add(node);
        }
        continue;
      }
      if (token.isNotEmpty) stack.last.children.add(_HtmlNode.text(token));
    }
    return root;
  }
}

const _voidTags = {
  'area',
  'base',
  'br',
  'col',
  'embed',
  'hr',
  'img',
  'input',
  'link',
  'meta',
  'param',
  'source',
  'track',
  'wbr',
};

Map<String, String> _parseAttributes(String source) {
  final attributes = <String, String>{};
  final pattern = RegExp(
    r'''([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))''',
  );
  for (final match in pattern.allMatches(source)) {
    attributes[match.group(1)!.toLowerCase()] =
        match.group(2) ?? match.group(3) ?? match.group(4) ?? '';
  }
  return attributes;
}

String _decodeEntities(String text) {
  var value = text
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');
  value = value.replaceAllMapped(
    RegExp(r'&#(x[0-9a-f]+|\d+);', caseSensitive: false),
    (match) {
      final code = match.group(1)!;
      final number = code.toLowerCase().startsWith('x')
          ? int.tryParse(code.substring(1), radix: 16)
          : int.tryParse(code);
      return number == null ? match.group(0)! : String.fromCharCode(number);
    },
  );
  return value;
}
