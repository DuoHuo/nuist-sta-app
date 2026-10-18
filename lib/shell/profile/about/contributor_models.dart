/// 一位贡献者。
class Contributor {
  const Contributor({required this.name, this.avatar});

  final String name;

  /// 头像地址，没有则显示名字首字的圆形占位。
  final String? avatar;

  /// name 缺失或为空时返回 null（调用方跳过该条）；avatar 非字符串或空串视为没有。
  static Contributor? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    if (name is! String || name.trim().isEmpty) return null;
    final avatar = json['avatar'];
    return Contributor(
      name: name.trim(),
      avatar: avatar is String && avatar.trim().isNotEmpty
          ? avatar.trim()
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    if (avatar != null) 'avatar': avatar,
  };
}

/// 解析接口响应 `{"code":0,"data":[{"name":..,"avatar":..}]}`。
///
/// code 不为 0 或 data 不是数组时抛 [FormatException]。
List<Contributor> parseContributorsResponse(Object? json) {
  if (json is! Map || json['code'] != 0 || json['data'] is! List) {
    throw const FormatException('贡献者接口响应格式不对');
  }
  return [for (final item in json['data'] as List) ?Contributor.fromJson(item)];
}

/// 本地缓存的贡献者名单。
class ContributorCache {
  const ContributorCache({required this.items, required this.fetchedAt});

  static const ttl = Duration(hours: 24);

  final List<Contributor> items;
  final DateTime fetchedAt;

  /// 距上次拉取满 [ttl] 即过期；fetchedAt 在未来（改过系统时间）也视为过期。
  bool isStale(DateTime now) {
    final age = now.difference(fetchedAt);
    return age >= ttl || age.isNegative;
  }

  static ContributorCache? fromJson(Object? json) {
    if (json is! Map) return null;
    final fetchedAt = DateTime.tryParse(json['fetchedAt']?.toString() ?? '');
    final items = json['items'];
    if (fetchedAt == null || items is! List) return null;
    return ContributorCache(
      items: [for (final item in items) ?Contributor.fromJson(item)],
      fetchedAt: fetchedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'fetchedAt': fetchedAt.toIso8601String(),
    'items': [for (final c in items) c.toJson()],
  };
}
