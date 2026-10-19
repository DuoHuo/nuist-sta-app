import 'dart:convert';

/// 单次响应 / 缓存最多保留的公告条数。
const int kMaxAnnouncements = 50;

/// 公告的提醒方式。
enum AnnouncementRemind {
  /// 不主动提醒，只亮红点。
  none,

  /// 首页小悬浮条弱提醒。
  badge,

  /// 首帧后自动弹出模态框。
  popup;

  /// 解析服务端字段，未知值退化为 [none]。
  static AnnouncementRemind parse(Object? raw) {
    for (final v in values) {
      if (v.name == raw) return v;
    }
    return none;
  }
}

/// 卡片配色基调，只影响颜色，不在 UI 上显示任何文字。
enum AnnouncementTone {
  normal,
  notice,
  alert;

  /// 解析服务端字段，未知值退化为 [normal]。
  static AnnouncementTone parse(Object? raw) {
    for (final v in values) {
      if (v.name == raw) return v;
    }
    return normal;
  }
}

/// 公告附带的链接，只接受 https。
class AnnouncementLink {
  const AnnouncementLink({required this.label, required this.url});

  final String label;
  final String url;

  /// 解析链接；非 Map、url 缺失或不是 https 时返回 null。
  static AnnouncementLink? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final url = raw['url'];
    if (url is! String) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    final label = raw['label'];
    return AnnouncementLink(
      label: label is String && label.trim().isNotEmpty ? label : '复制链接',
      url: url,
    );
  }

  Map<String, dynamic> toJson() => {'label': label, 'url': url};
}

DateTime? _parseDate(Object? raw) =>
    raw is String ? DateTime.tryParse(raw) : null;

String? _parseString(Object? raw) =>
    raw is String && raw.trim().isNotEmpty ? raw : null;

/// 一条公告。
class Announcement {
  const Announcement({
    required this.id,
    required this.title,
    this.summary,
    this.content = '',
    this.publishedAt,
    this.expiresAt,
    this.pinned = false,
    this.remind = AnnouncementRemind.none,
    this.dismissible = true,
    this.tone = AnnouncementTone.normal,
    this.minAppVersion,
    this.maxAppVersion,
    this.link,
  });

  final String id;
  final String title;
  final String? summary;

  /// 纯文本，`\n` 换行。
  final String content;
  final DateTime? publishedAt;
  final DateTime? expiresAt;
  final bool pinned;
  final AnnouncementRemind remind;

  /// 服务端原值；实际是否阻断看 [blocking]。
  final bool dismissible;
  final AnnouncementTone tone;
  final String? minAppVersion;
  final String? maxAppVersion;
  final AnnouncementLink? link;

  /// 不可关闭的公告。必须带 expiresAt，否则视为可关闭，避免永久挡住首页。
  bool get blocking => !dismissible && expiresAt != null;

  /// 本地时间是否已过期。
  bool isExpired(DateTime now) => expiresAt != null && expiresAt!.isBefore(now);

  /// 容错解析；非 Map 或缺 id/title 时返回 null，未知字段忽略。
  static Announcement? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = _parseString(raw['id']);
    final title = _parseString(raw['title']);
    if (id == null || title == null) return null;
    final content = raw['content'];
    final dismissible = raw['dismissible'];
    return Announcement(
      id: id,
      title: title,
      summary: _parseString(raw['summary']),
      content: content is String ? content : '',
      publishedAt: _parseDate(raw['publishedAt']),
      expiresAt: _parseDate(raw['expiresAt']),
      pinned: raw['pinned'] == true,
      remind: AnnouncementRemind.parse(raw['remind']),
      dismissible: dismissible is bool ? dismissible : true,
      tone: AnnouncementTone.parse(raw['tone']),
      minAppVersion: _parseString(raw['minAppVersion']),
      maxAppVersion: _parseString(raw['maxAppVersion']),
      link: AnnouncementLink.tryParse(raw['link']),
    );
  }

  /// 序列化，供缓存回写；与 [tryParse] 往返一致。
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'summary': summary,
    'content': content,
    'publishedAt': publishedAt?.toIso8601String(),
    'expiresAt': expiresAt?.toIso8601String(),
    'pinned': pinned,
    'remind': remind.name,
    'dismissible': dismissible,
    'tone': tone.name,
    'minAppVersion': minAppVersion,
    'maxAppVersion': maxAppVersion,
    'link': link?.toJson(),
  };
}

/// 解析条目列表：畸形项跳过，重复 id 保留第一条，最多 [kMaxAnnouncements] 条。
List<Announcement> _parseItems(List raw) {
  final seen = <String>{};
  final out = <Announcement>[];
  for (final e in raw) {
    final a = Announcement.tryParse(e);
    if (a == null || !seen.add(a.id)) continue;
    out.add(a);
    if (out.length >= kMaxAnnouncements) break;
  }
  return out;
}

/// 解析接口响应（Map 或 JSON 字符串）。`items` 不是数组时抛 [FormatException]。
List<Announcement> parseAnnouncementResponse(Object? data) {
  final decoded = data is String ? jsonDecode(data) : data;
  if (decoded is! Map || decoded['items'] is! List) {
    throw const FormatException('公告响应格式错误');
  }
  return _parseItems(decoded['items'] as List);
}

/// 比较语义化版本号：取 `+` 前部分按 `.` 拆数字，缺位补 0，非数字段视为 0。
int compareVersions(String a, String b) {
  List<int> parts(String v) => v
      .split('+')
      .first
      .split('.')
      .map((s) => int.tryParse(s.trim()) ?? 0)
      .toList();
  final pa = parts(a), pb = parts(b);
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

/// 客户端过滤与排序：去掉过期、不在版本区间内的项（[appVersion] 为 null 时
/// 不做版本过滤）；置顶优先，再按发布时间降序（无发布时间排最后）。
List<Announcement> visibleAnnouncements(
  List<Announcement> all, {
  required DateTime now,
  required String? appVersion,
}) {
  final list = all.where((a) {
    if (a.isExpired(now)) return false;
    if (appVersion != null) {
      if (a.minAppVersion != null &&
          compareVersions(appVersion, a.minAppVersion!) < 0) {
        return false;
      }
      if (a.maxAppVersion != null &&
          compareVersions(appVersion, a.maxAppVersion!) > 0) {
        return false;
      }
    }
    return true;
  }).toList();
  list.sort((a, b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    final pa = a.publishedAt, pb = b.publishedAt;
    if (pa == null && pb == null) return 0;
    if (pa == null) return 1;
    if (pb == null) return -1;
    return pb.compareTo(pa);
  });
  return list;
}

/// 公告本地缓存：原始列表 + 条件请求用的校验头。
class AnnouncementCache {
  const AnnouncementCache({
    required this.items,
    this.etag,
    this.lastModified,
    required this.fetchedAt,
  });

  final List<Announcement> items;
  final String? etag;
  final String? lastModified;
  final DateTime fetchedAt;

  /// 从 JSON 还原；结构不对时抛 [FormatException]。
  factory AnnouncementCache.fromJson(Object? json) {
    if (json is! Map || json['items'] is! List) {
      throw const FormatException('公告缓存格式错误');
    }
    final fetchedAt = _parseDate(json['fetchedAt']);
    if (fetchedAt == null) throw const FormatException('公告缓存缺少时间');
    return AnnouncementCache(
      items: _parseItems(json['items'] as List),
      etag: _parseString(json['etag']),
      lastModified: _parseString(json['lastModified']),
      fetchedAt: fetchedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'items': [for (final a in items) a.toJson()],
    'etag': etag,
    'lastModified': lastModified,
    'fetchedAt': fetchedAt.toIso8601String(),
  };
}
