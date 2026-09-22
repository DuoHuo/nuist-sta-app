/// Optional capability: existing map/navigation sources need not provide models.
abstract interface class CampusBuildingModelSource {
  Future<CampusBuildingModel?> loadBuildingModel(String buildingId);
  Uri buildingModelViewerUri(String buildingId, {int? levelIndex});
}

class CampusBuildingModel {
  const CampusBuildingModel({
    required this.url,
    required this.floors,
    this.version,
    this.sha256,
    this.sizeBytes,
  });

  final Uri url;
  final List<CampusModelFloor> floors;
  final String? version, sha256;
  final int? sizeBytes;

  factory CampusBuildingModel.fromJson(
    Map<String, dynamic> data,
    Uri serverRoot,
  ) {
    // The viewer owns GLB/schema interpretation. Model discovery only relies
    // on the public URL/version/floors contract.
    Uri resource(dynamic value) {
      if (value is! String || value.trim().isEmpty) {
        throw const FormatException('三维模型缺少文件地址');
      }
      final uri = serverRoot.resolve(value.trim());
      if (!uri.hasAuthority || !['http', 'https'].contains(uri.scheme)) {
        throw const FormatException('三维模型文件地址无效');
      }
      return uri;
    }

    final values = data['floors'];
    if (values is! List) {
      throw const FormatException('三维模型楼层信息无效');
    }
    final seen = <int>{};
    final floors = <CampusModelFloor>[];
    for (final value in values) {
      if (value is! Map<String, dynamic> || value['level_index'] is! int) {
        throw const FormatException('三维模型楼层编号无效');
      }
      final level = value['level_index'] as int;
      if (!seen.add(level)) {
        throw const FormatException('三维模型楼层编号重复');
      }
      final name = value['display_name']?.toString().trim();
      final elevation = value['elevation_m'];
      if (elevation != null && (elevation is! num || !elevation.isFinite)) {
        throw const FormatException('三维模型楼层标高无效');
      }
      floors.add(
        CampusModelFloor(
          elevationM: (elevation as num?)?.toDouble(),
          levelIndex: level,
          displayName: name == null || name.isEmpty
              ? (level < 0 ? 'B${-level}' : '${level + 1}F')
              : name,
          nodeName: value['node_name']?.toString(),
          url: value['url'] == null ? null : resource(value['url']),
        ),
      );
    }
    floors.sort((a, b) => a.levelIndex.compareTo(b.levelIndex));
    return CampusBuildingModel(
      url: resource(data['url']),
      floors: List.unmodifiable(floors),
      version: data['version']?.toString(),
      sha256: data['sha256']?.toString(),
      sizeBytes: data['size_bytes'] is int ? data['size_bytes'] as int : null,
    );
  }
}

class CampusModelFloor {
  const CampusModelFloor({
    required this.levelIndex,
    required this.displayName,
    this.elevationM,
    this.nodeName,
    this.url,
  });

  final int levelIndex;
  final String displayName;
  final double? elevationM;
  final String? nodeName;
  final Uri? url;
}
