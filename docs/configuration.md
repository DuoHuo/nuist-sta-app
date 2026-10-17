# 校园地址与密钥的存储方式

学校要求仓库源码里不出现校内域名、IP 和密钥的明文。做法是**把真实值 hex 编码后
集中存放在一个文件里**，运行时解码使用；`flutter run` / `flutter build` 都不需要
额外参数。

> ⚠️ 这是**编码，不是加密**。拿到源码或 APK 的人都能还原，所以这些值按"公开"
> 对待，不要当成真正的机密；它的唯一目的是让仓库里不出现字面量。

## 唯一入口

`lib/core/config/campus_config.dart`：

| 常量（hex） | 解码后 |
|---|---|
| `_rootHex` | 校园根域，所有子域由它派生 |
| `_mapBaseUrlHex` | 校园地图后端地址（HTTPS 域名，`duohuo.org.cn` 的地图子域） |
| `_passkeyExportKeyHex` | 通行密钥导出用的内置 AES 密钥（16 个 ASCII 字符） |
| `_vpnSpaKeyHex` | Enlink SSL VPN 的 SPA 敲门密钥 |

导出的 `CampusHosts`（`authserver` / `jwxt` / `icard` / `iportal` / `bulletin` /
`labor` / `cxcyjy` / `cxxf` / `vpnController`）全部由根域派生，业务代码只引用它。

**改地址或密钥**时只改这一处。生成 hex：

```bash
python -c "print('your-host.example'.encode().hex())"
# 或 PowerShell
-join ('your-host.example'.ToCharArray() | ForEach-Object { [int][char]$_ | ForEach-Object { $_.ToString('x2') } })
```

只支持 ASCII（解码用 `String.fromCharCodes`）。

## Android 明文放行清单

`android/app/src/main/res/xml/` 下的 NSC 是原生资源，不能执行 Dart。`android/app/build.gradle.kts` 会从 `campus_config.dart` 里用正则取出
`_mapBaseUrlHex`、解码后生成 NCC，输出到 `build/app/generated/nsc/`（不入库）：

- release：只放行地图主机 + `duohuo.org.cn`（地图现在是 HTTPS 域名，这条明文放行
  实际不会用到，保留是为了兼容本地把地址临时改成 HTTP 的情况）；
- debug：额外放行 `127.0.0.1` / `localhost` / `10.0.2.2`，并信任用户 CA（抓包用）。

## 代码约定

- 校内域名一律从 `CampusHosts` 派生，禁止硬编码；明文值只能出现在
  `campus_config.dart` 的 hex 常量里（且必须是 hex）。
- 只模板化主机名；路径、大小写、尾斜杠保持服务端原样（CAS 精确匹配 service）。
- 配置值在运行时解码，所以是 `final` 而不是 `const`；需要默认参数的 API 用可空
  参数 + `??` 兜底。
- CI 的 `Check for sensitive literals` 会拦截：`*.edu.cn`、`202.19x` IP、明文私钥、
  硬编码的导出密钥、12 位学号（合成夹具白名单除外）。规则刻意写成通用正则，
  避免守卫脚本自身泄露真实值。

## 边界

- **二进制里仍是明文**：本方案只保证仓库源码的字面量检查通过，APK 里解包/运行
  都能拿到真实值。若验收也扫二进制，只能改成服务端下发配置。
- 误提交真实值（或把 hex 换回明文）时，改文件不够：需要重写 git 历史。
- 密钥（`_passkeyExportKeyHex` / `_vpnSpaKeyHex`）随源码公开，按已泄露处理，不要
  用于真正的机密。
