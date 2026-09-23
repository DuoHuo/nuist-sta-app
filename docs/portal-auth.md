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
| `rpId` | 依赖方标识，即 `authserver.campus.invalid` |
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

- 不要随手改写大小写或尾斜杠。例如 `labor` 的 URL 里 **`Labor` 的首字母大写是服务端原样给的**
- 编码方式也是复刻 Python 的 `quote(service, safe=':/')`：协议和路径分隔符不转义，
  其余转义 —— 编码形式变了可能导致 ticket 验证失败
- service 写错时最直接的可见症状是：登录后又跳回 `/authserver/login`

## 安全边界

- **私钥不离开设备**。签名在本地完成，出网的只有 `signature` + `credentialId` +
  `authenticatorData` + `clientDataJSON`
- 会话 Cookie 用 `FlutterSecureStorage` 存，**没有**用 `cookie_jar` 默认的明文文件存储 ——
  门户会话 Cookie 等同于登录态，值得和私钥享受同一层保护
- **没有任何遥测 / 崩溃上报 / 上传**。网络出口只有学校自己的域名，外加补全证书链时
  拉取证书里自带的 CA Issuers 地址
- 日志在 release 构建下完全静默；URL 打印前会去掉 query（顺带避免 ticket 落进日志）；
  Cookie 调试接口只返回名字不返回值

## 已知缺口

- **webvpn 模式未移植**。`NuistLogin.login()` 已经预留了 `base` 参数（webvpn 的代理前缀
  可以直接顶替 authserver 根地址，流程一个字都不用改），但 **VPN Cookie 的获取与失效
  重试还没做**
- **`lib/core/auth/` 暂无单元测试**
