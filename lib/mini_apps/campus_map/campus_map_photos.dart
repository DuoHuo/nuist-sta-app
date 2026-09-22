/// 建筑实拍图片（由后端返回，客户端不生成任何图片数据）。
class CampusPhoto {
  const CampusPhoto({
    required this.id,
    required this.url,
    this.caption = '',
    this.source = '',
    this.takenAt,
  });

  final int id;

  /// 图片绝对地址（已按接口基址解析）。
  final String url;
  final String caption;
  final String source;
  final DateTime? takenAt;

  String get label => caption.isNotEmpty ? caption : source;
}

/// 实拍图片数据源。实现方负责把后端字段映射为该模型。
abstract interface class CampusBuildingPhotosSource {
  Future<List<CampusPhoto>> loadBuildingPhotos(String buildingId);
}

class CampusPhotoException implements Exception {
  const CampusPhotoException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 把 `/photos/<file>` 之类的相对路径解析为可加载的绝对地址。
Uri resolvePhotoUri(Uri apiBase, String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    throw const CampusPhotoException('实拍图片缺少地址');
  }
  final uri = apiBase.resolve(trimmed);
  // 必须是可加载的绝对地址，且指向具体文件而非站点根。
  if (uri.host.isEmpty ||
      !uri.hasScheme ||
      uri.pathSegments.isEmpty ||
      uri.path == '/') {
    throw const CampusPhotoException('实拍图片地址无效');
  }
  return uri;
}

/// 解析后端返回的图片列表；字段缺失或非法时给出可读错误。
List<CampusPhoto> parsePhotos(
  Uri apiBase,
  List<Object?> raw, {
  bool strict = true,
}) {
  final photos = <CampusPhoto>[];
  for (final item in raw) {
    if (item is! Map) {
      if (strict) throw const CampusPhotoException('实拍图片数据格式不正确');
      continue;
    }
    final data = Map<String, dynamic>.from(item);
    final id = data['photo_id'];
    final url = data['url'];
    if (id is! int || url is! String || url.trim().isEmpty) {
      if (strict) throw const CampusPhotoException('实拍图片数据缺少必要字段');
      continue;
    }
    final takenAt = data['taken_at'];
    photos.add(
      CampusPhoto(
        id: id,
        url: resolvePhotoUri(apiBase, url).toString(),
        caption: (data['caption'] as String?)?.trim() ?? '',
        source: (data['source'] as String?)?.trim() ?? '',
        takenAt: takenAt is String ? DateTime.tryParse(takenAt) : null,
      ),
    );
  }
  return photos;
}
