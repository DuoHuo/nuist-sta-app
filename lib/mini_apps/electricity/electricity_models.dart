/// 一卡通级联选择里的一项：区域 / 楼栋 / 房间都是这个形状。
///
/// [value] 是服务端要的原始串（形如 `1&晖园`，带 `&`），只展示 [name]。
class ElecOption {
  const ElecOption({required this.name, required this.value});

  factory ElecOption.fromJson(Map<String, dynamic> json) => ElecOption(
    name: (json['name'] ?? '').toString(),
    value: (json['value'] ?? '').toString(),
  );

  final String name;
  final String value;

  Map<String, dynamic> toJson() => {'name': name, 'value': value};

  @override
  bool operator ==(Object other) =>
      other is ElecOption && other.name == name && other.value == value;

  @override
  int get hashCode => Object.hash(name, value);
}

/// 用户绑定的宿舍。
class ElecRoom {
  const ElecRoom({
    required this.campus,
    required this.building,
    required this.room,
  });

  factory ElecRoom.fromJson(Map<String, dynamic> json) => ElecRoom(
    campus: ElecOption.fromJson(json['campus'] as Map<String, dynamic>),
    building: ElecOption.fromJson(json['building'] as Map<String, dynamic>),
    room: ElecOption.fromJson(json['room'] as Map<String, dynamic>),
  );

  final ElecOption campus;
  final ElecOption building;
  final ElecOption room;

  Map<String, dynamic> toJson() => {
    'campus': campus.toJson(),
    'building': building.toJson(),
    'room': room.toJson(),
  };

  /// 历史记录按宿舍分区的主键。
  String get key => '${campus.value}|${building.value}|${room.value}';

  /// 「沁园 · 36栋标准公寓 · 315」。楼栋名往往已含区域名，重复时只留楼栋。
  String get displayName {
    final parts = [
      if (!building.name.contains(campus.name)) campus.name,
      building.name,
      room.name,
    ];
    return parts.join(' · ');
  }
}

/// 一次查询到的剩余电量。
class ElecReading {
  const ElecReading({required this.time, required this.kwh});

  final DateTime time;
  final double kwh;
}
