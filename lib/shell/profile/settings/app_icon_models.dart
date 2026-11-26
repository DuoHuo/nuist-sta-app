import 'dart:typed_data';

/// 内置应用图标的稳定标识；原生端按这个 id 启用对应的桌面入口。
abstract final class AppIconIds {
  static const defaultIcon = 'default';
  static const alt = 'alt';
  static const mascot = 'mascot';
  static const mascotColor = 'mascot_color';
}

/// 一个内置图标的展示信息。
class AppIconChoice {
  const AppIconChoice({
    required this.id,
    required this.label,
    required this.assetPath,
  });

  final String id;
  final String label;
  final String assetPath;
}

/// 设置页展示的内置图标。
const appIconChoices = <AppIconChoice>[
  AppIconChoice(
    id: AppIconIds.defaultIcon,
    label: '默认',
    assetPath: 'assets/images/app_icon.png',
  ),
  AppIconChoice(
    id: AppIconIds.mascot,
    label: '信小龙',
    assetPath: 'assets/images/app_icon_mascot.png',
  ),
  AppIconChoice(
    id: AppIconIds.mascotColor,
    label: '派龙',
    assetPath: 'assets/images/app_icon_mascot_color.png',
  ),
  AppIconChoice(
    id: AppIconIds.alt,
    label: '海海',
    assetPath: 'assets/images/app_icon_alt.png',
  ),
];

/// 原生端返回的图标状态。字段全部做了防御性解析，避免版本不一致时页面崩溃。
class AppIconState {
  const AppIconState({
    required this.supported,
    required this.builtinId,
    required this.canPin,
    required this.customPinned,
    required this.pending,
    this.customIcon,
  });

  /// 当前设备或系统版本是否支持应用图标功能。
  final bool supported;

  /// 当前生效的内置图标 id。
  final String builtinId;

  /// 当前桌面是否支持创建快捷方式。
  final bool canPin;

  /// 自定义图标快捷方式是否已经固定到桌面。
  final bool customPinned;

  /// 原生端是否还在等待系统确认创建快捷方式。
  final bool pending;

  /// 已处理的自定义图标 PNG；原生端没有保存时为空。
  final Uint8List? customIcon;

  static const _builtinIds = {
    AppIconIds.defaultIcon,
    AppIconIds.alt,
    AppIconIds.mascot,
    AppIconIds.mascotColor,
  };

  /// 不支持平台时的保守状态。
  static const unsupported = AppIconState(
    supported: false,
    builtinId: AppIconIds.defaultIcon,
    canPin: false,
    customPinned: false,
    pending: false,
  );

  /// 从平台通道的 Map 解析状态。
  factory AppIconState.fromPlatform(Object? value) {
    if (value is! Map) return unsupported;
    final map = value.cast<Object?, Object?>();
    final rawBuiltin = map['builtinId'];
    final builtinId = rawBuiltin is String && _builtinIds.contains(rawBuiltin)
        ? rawBuiltin
        : AppIconIds.defaultIcon;
    final rawIcon = map['customIcon'];
    final customIcon = switch (rawIcon) {
      Uint8List bytes when bytes.isNotEmpty => Uint8List.fromList(bytes),
      List<int> values when values.isNotEmpty => Uint8List.fromList(values),
      _ => null,
    };
    return AppIconState(
      supported: map['supported'] == true,
      builtinId: builtinId,
      canPin: map['canPin'] == true,
      customPinned: map['customPinned'] == true,
      pending: map['pending'] == true,
      customIcon: customIcon,
    );
  }

  /// 返回当前内置图标对应的展示项。
  AppIconChoice get choice => appIconChoices.firstWhere(
    (item) => item.id == builtinId,
    orElse: () => appIconChoices.first,
  );
}
