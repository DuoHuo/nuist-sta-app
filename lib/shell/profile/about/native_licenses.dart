import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 原生组件许可证正文的资源路径。
const nativeLicensesAsset = 'assets/licenses/native_licenses.txt';

/// 资源文件里各条目之间的分隔行。
const _separator = '-----8<-----';

/// 解析 [nativeLicensesAsset] 的内容：条目以 `-----8<-----` 分隔，每条第一行是组件名，
/// 空一行后是许可证正文。
@visibleForTesting
List<LicenseEntry> parseNativeLicenses(String source) {
  final entries = <LicenseEntry>[];
  for (final section in source.split(_separator)) {
    final text = section.trim();
    if (text.isEmpty) continue;
    final newline = text.indexOf('\n');
    if (newline < 0) continue;
    final name = text.substring(0, newline).trim();
    final body = text.substring(newline).trim();
    if (name.isEmpty || body.isEmpty) continue;
    entries.add(LicenseEntryWithLineBreaks([name], body));
  }
  return entries;
}

/// 登记 Flutter 不会自动收集的原生组件，让「开源许可」页能列出它们及完整正文。
///
/// Dart 依赖由 Flutter 根据各包的 LICENSE 文件自动收集；校园 VPN 的 Rust 依赖
/// （`native/vpn`）、Android 端的 Gradle 依赖和 `flutter_zxing` 内置的 C++ 库不在其中，
/// 它们的许可证正文保存在 [nativeLicensesAsset]。增删这些依赖时需要同步更新该文件。
/// 读取失败时只是少列这些条目，不影响应用运行。
void registerNativeLicenses() {
  LicenseRegistry.addLicense(() async* {
    final String source;
    try {
      source = await rootBundle.loadString(nativeLicensesAsset);
    } catch (_) {
      return;
    }
    yield* Stream.fromIterable(parseNativeLicenses(source));
  });
}
