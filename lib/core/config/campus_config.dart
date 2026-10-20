/// 校内服务地址与密钥。
///
/// 这里存的是 **hex 编码**，不是加密：只为让仓库里不出现明文域名、IP 和密钥。
/// 拿到源码或 APK 的人都能还原，因此这些值按"公开"对待，不要用于真正的机密。
///
/// 修改步骤：把新值按 ASCII 编码成 hex（例如
/// `python -c "print('your-host'.encode().hex())"`），替换下面四个常量即可；
/// Android 的 network_security_config.xml 会由 Gradle 从本文件解析 hex 后生成。
library;

/// 把 hex 还原成 ASCII 文本。
String _decodeHex(String hex) => String.fromCharCodes([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);

// 校园根域
const String _rootHex = '6e756973742e6564752e636e';

// 校园地图后端地址（HTTPS 域名）
const String _mapBaseUrlHex =
    '68747470733a2f2f6d61702e64756f68756f2e6f72672e636e';

// 公交公开页面与状态服务主机
const String _shuttlePageUrlHex =
    '687474703a2f2f7777772e6e732d7265732e636e2f68796478666c61742f696e646578656c63742e68746d6c';
const String _shuttleApiHostHex = '34372e39362e31362e3233';

// 通行密钥导出用的内置 AES 密钥（16 个 ASCII 字符）
const String _passkeyExportKeyHex = '4855575173365856766c72736b41577a';

// Enlink SSL VPN 的 SPA 敲门密钥
const String _vpnSpaKeyHex = '456e6c696e6b40313233';

/// 校园根域，所有子域由它派生。
final String kCampusRootDomain = _decodeHex(_rootHex);

/// 校园地图后端地址；空串表示未配置。
final String kCampusMapBaseUrl = _decodeHex(_mapBaseUrlHex);

/// 公交公开页面，用于发现当前登录接口。
final String kCampusShuttlePageUrl = _decodeHex(_shuttlePageUrlHex);

/// 通行密钥导出用的内置 AES 密钥。
final String kPasskeyExportKey = _decodeHex(_passkeyExportKeyHex);

/// Enlink SSL VPN 的 SPA 敲门密钥。
final String kVpnSpaKey = _decodeHex(_vpnSpaKeyHex);

/// 校内主机名，全部由 [kCampusRootDomain] 派生。
///
/// 只模板化主机名，路径、大小写、尾斜杠都必须保持服务端原样（CAS 精确匹配
/// service 字符串）。
abstract final class CampusHosts {
  /// 公交网页当前使用的状态服务主机。
  static final shuttleApi = _decodeHex(_shuttleApiHostHex);
  static final authserver = 'authserver.$kCampusRootDomain';
  static final jwxt = 'jwxt.$kCampusRootDomain';
  static final icard = 'icard.$kCampusRootDomain';
  static final iportal = 'i.$kCampusRootDomain';
  static final bulletin = 'bulletin.$kCampusRootDomain';
  static final labor = 'labor.$kCampusRootDomain';
  static final cxcyjy = 'cxcyjy.$kCampusRootDomain';
  static final cxxf = 'cxxf.$kCampusRootDomain';
  static final vpnController = 'client.vpn.$kCampusRootDomain';
}
