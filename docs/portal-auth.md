# 统一门户登录

学校各业务系统（教务、一卡通、信息门户…）都挂在统一的 CAS 门户后面。这个模块
（`lib/core/auth/`）负责一件事：**用本机保存的 Passkey 凭据，在纯网络层完成登录，
并把会话共享给所有小程序。**

## 凭据

绑定后，凭据以 `PasskeyBundle`（`passkey_bundle.dart`）的形式存在
**`flutter_secure_storage`**（Android Keystore / iOS Keychain）里，storage key 是
`nuist_portal_passkey`。

| 字段 | 含义 |
|---|---|
| `rpId` | 依赖方标识，即门户 CAS 主机名（`authserver.<校园根域>`，根域 hex 编码存储在 `campus_config.dart`，见 [校园地址与密钥](configuration.md)） |
| `credentialId` | 凭据 ID |
| `privateKeyPkcs8Pem` | **P-256 私钥**（PKCS#8 PEM） |
| `userId` | 学号的 Base64URL 形式 |
| `anonbiometricsd` | 服务端下发的匿名生物识别标识 |
| `deviceName` | 绑定设备名，形如 `NUIST++ (Android)` |
| `createdAt` | 绑定时间 |

序列化格式是 JSON，**前五个字段与 Python 参考实现的 `passkey.local.json` 逐字一致**，
两边可以互换使用。

`studentId` 是从 `userId` 本地 Base64URL 解码派生的 getter（要求解码结果匹配
`^\d{6,20}$`），纯本地计算、不联网。

> 绑定流程（在 WebView 里注册 Passkey）属于端上适配细节，本文不展开，见
> `lib/shell/profile/portal_bind/` 与 `assets/js/portal_passkey.js`。

## PortalSession

全局单例（`PortalSession.instance`），所有小程序共用。

### 公开 API

| 成员 | 语义 |
|---|---|
| `ensureLoggedIn(service, {force, trustRestored, onStage})` | 确保 `service` 已登录，返回**落地 URL**。`force: true` 无视缓存重登（有同 service 登录在飞则直接合流）；`trustRestored: false` 不采信磁盘恢复、本进程未验证的缓存 |
| `clientFor(service, {force})` | 先 `ensureLoggedIn` 再返回带会话 Cookie 的客户端，适合精细控制请求 |
| `request(service, send)` | 高层封装：带会话发请求 + 失效自动重登重放。**最常用** |
| `http` | 共享全局 Cookie 的裸客户端，**不保证任何登录态** |
| `syncToWebView(urls)` | 把会话 Cookie 灌进 WebView |
| `clear({includeWebView})` | 清空会话（**不清 `_pending`**） |
| `verifyCredential({service, onStage})` | 先 `clear()` 再强制重登，用于「测试登录」验证凭据是否还有效 |
| `credentialError` | `ValueNotifier<PortalCredentialError?>`，UI 监听它显示「已失效」 |
| `debugCookieNames(url)` | 仅调试用。**只返回 Cookie 名和域，不返回值** |

调用 `verifyCredential` 而不是普通登录来验凭据，是因为票根还有效时会走下面的 SSO 快路径、
**压根不碰 Passkey**，验不出凭据是否被吊销。

### 会话落盘复用

用 `PersistCookieJar` 持久化到安全存储。两个开关**必须都开**：

```dart
persistSession: true,   // 无 expires 的会话 Cookie 也要存
ignoreExpires: true,    // 忽略过期时间
```

CASTGC 和 JSESSIONID 都是**没有 `expires` 的会话 Cookie**，不开等于什么都没存。

Cookie 拦截器用的是 `PortalCookieManager`（`portal_cookie_manager.dart`），门户会话与
VPN 认证（`core/network/vpn_auth.dart`）共用。`dio_cookie_manager` 默认会把重定向响应的
Cookie 另存到 `Location` 目标上，导致 host-only Cookie 跨域混用、无 Path 的 Cookie
被复制到别的路径，进而出现偶发的无限重定向；这里改为每一跳只按响应来源保存自己的 Cookie。

个别学校平台（如劳动教育）会在 HTTPS 响应里下发 `SameSite=None` 却漏掉 `Secure`。
dart:io 按 RFC 6265bis 会直接抛异常，`dio_cookie_manager` 进而把整条响应判为保存失败，
同响应里合法的会话 Cookie 也一起丢掉。原生客户端不实现 SameSite 语义，`PortalCookieManager`
会去掉这个非法属性再保存；实在无法解析的 Cookie 只丢弃单条，不再拖垮整次登录。

service → 落地 URL 表（`_established`）也经 `EstablishedStore` 落到同一安全存储，
冷启动读回。落地 URL 里有 icard 的 JWT，不落盘的话电费每次启动都得重新过 CAS。
条目信任期 12 小时（`establishedTtl`），超过后当作未命中，重新走一次 SSO 快路径确认。

### CAS 票根快路径

换 service 时通常不需要重新签名：

1. **落地缓存**：`_established[service]` 命中（含磁盘恢复且未过信任期的）就直接返回，一次网络都不发
2. **服务端 SSO**：没命中时打开 `authserver/login?service=…`，如果最终落地的 URL
   **不含** `/authserver/login`，说明 CASTGC 票根仍有效、服务端直接放行了，于是跳过签名
3. **串行化保证快路径生效**：所有登录排在一个全局队列里，让后来者等前一个把票根建起来

也就是说：第一个 service 走完整的 Passkey 断言，之后换 service 由服务端直接放行。

### 失效自动重登与重放

`request()` 的逻辑：拿到响应后判断它是不是被拦回了登录页；是的话强制重登一次并重放请求。

> **⚠️ 这意味着 `send` 回调可能被调用两次。** 别在里面放有副作用的逻辑。

重登后仍被拦回登录页，抛 `PortalLoginError`。

### 并发

- **`_pending` 合流**：同一个 service 的并发请求共用一个 Future —— 三个小程序同时启动
  不会登三次
- **`_queue` 串行**：任何 service 的登录都排队执行（全局单队列，不是按 service 分锁）
- 队列在任务失败时也推进，一次失败不会把队列卡死

## 异常体系

`PortalException` 是 `sealed class`，三个子类：

| 类型 | 含义 | UI 应该怎么处理 |
|---|---|---|
| `PortalNetworkError` | 网络层失败，**不能**推断凭据已吊销 | 提示重试 |
| `PortalCredentialError` | 凭据不可用（被吊销 / 未绑定 / 解析失败） | 引导重新绑定 |
| `PortalLoginError` | 其他：响应结构对不上、service 不正确、跳回认证页等 | 提示稍后再试 |

常见触发条件：

- **凭据被吊销最常见的形态**：`startAssertion` 返回 HTTP 200 + `{"message":"未查询到设备信息"}`，
  **没有 `success` 字段** —— 代码专门识别这种情况
- 服务端返回的 `allowCredentials` 列表里不含本机 `credentialId`
- 提交登录后**没返回 3xx 重定向**
- 超时 / 连不上 / 证书校验失败 → `PortalNetworkError`

**务必把前两类区分开**：把「没网」说成「需要重新绑定」，会让用户白跑一趟去重绑。
参考实现：`portal_status_page.dart` 用穷尽 `switch` 做映射。

## 服务白名单

`PortalServices` 定义了 5 个 service 常量（教务 `jwxt`、一卡通 `icard`、信息门户 `iportal`、
双创平台 `cxcyjy`、劳动教育 `labor`）。

**CAS 服务端按字符串精确匹配校验 service，改一个字就登不上。** 所以：

- 不要随手改写大小写或尾斜杠。`labor` 的主机名已统一小写并实测 CAS 校验通过；
  校内主机名只能通过 `CampusHosts`（`lib/core/config/campus_config.dart`）派生，
  真实根域 hex 编码存放在同一文件
- 编码方式也是复刻 Python 的 `quote(service, safe=':/')`：协议和路径分隔符不转义，
  其余转义 —— 编码形式变了可能导致 ticket 验证失败
- service 写错时最直接的可见症状是：登录后又跳回 `/authserver/login`

## 安全边界

- **私钥默认不离开设备**。签名在本地完成，出网的只有 `signature` + `credentialId` +
  `authenticatorData` + `clientDataJSON`。唯一的例外是用户在「统一门户」页主动
  **导出通行密钥**（`PasskeyTransfer`，见下）。
- **导出物的强度只取决于六位 PIN**。`passkey_transfer.dart` 把 hex 编码存储的
  16 字节文本密钥（`kPasskeyExportKey`）末六字节换成 PIN（ASCII），
  直接作为 AES-128-CFB 的密钥，IV 固定全零（不把 IV 额外塞进二维码）；但内置密钥
  和 APK 打包在一起，拆包即得，只挡"顺手看一眼"。真正的门槛只有 10^6 的 PIN 空间，
  没有任何拉伸，离线穷举瞬间可破——所以 UI 上反复提醒导出物
  等同登录凭据，传完即删。格式：`nuistkey1:` + Base45(密文)；
  明文是紧凑二进制（Base64URL / hex 字段解回原始字节，PKCS#8 只留 32 字节标量按
  WebCrypto 模板重建——私钥不是这个模板就直接判定无法导出，不做降级存储），
  设备名称按 UTF-8 变长字段保存。
  二维码 / 剪贴板 / `.nuistkey` 文件三种渠道装的是同一个字符串；导出页画二维码时
  把 Base45 主体放进 alphanumeric 段（`_exportQrCode`），比按 byte 模式编码少两个
  版本（V6 41×41 而不是 V8 49×49）
- 会话 Cookie 用 `FlutterSecureStorage` 存，**没有**用 `cookie_jar` 默认的明文文件存储 ——
  门户会话 Cookie 等同于登录态，值得和私钥享受同一层保护
- **没有任何遥测 / 崩溃上报 / 上传**。门户登录链路只访问学校自己的域名，外加补全证书链时
  拉取证书里自带的 CA Issuers 地址。App 整体还有几个非学校出口，都不携带门户凭据或会话：
  社团自有服务 `app.duohuo.org.cn`（公告、贡献者名单）、校园地图后端（`duohuo.org.cn`
  子域）、第三方小公交页面与状态服务
- release 构建只在本机缓存中有限保存经过脱敏的 INFO 及以上诊断日志，不自动上传；详细日志
  默认关闭，连续点击「关于」页版本号 5 次后临时开启，debug 构建则默认开启。门户日志不记录 URL、Cookie、ticket、JWT、凭据或响应正文，
  主机名会匿名化；Cookie 调试接口也只返回名字不返回值

## 已知缺口

- **webvpn 模式未移植**，也不再计划移植：校外访问改由内置 VPN 承担（`core/network/`，
  用法见 [架构文档](architecture.md#校园-vpn-网络请求)），VPN 认证复用 `NuistLogin` 与本机
  Passkey。`NuistLogin.login()` 的 `base` 参数仍保留为扩展位
- **`lib/core/auth/` 测试覆盖不全**：`NuistLogin`、`PortalCookieManager` 和学号掩码有单元测试，
  `PortalSession`、`PasskeyTransfer` 等还没有
