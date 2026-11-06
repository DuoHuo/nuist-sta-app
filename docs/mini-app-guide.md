# 新增一个小程序

小程序有两条路：**原生**（Flutter 页面，体验统一、可离线）和 **H5**（任意 Web 技术栈，
交给不会 Flutter 的社团）。

先读 [架构文档](architecture.md#一个小程序能贡献的四种-ui-面)里的「四种 UI 面」一节 ——
宫格入口、首页卡片、学习页卡片和全屏入口都通过 manifest 声明，再统一登记到注册表。

## 方式一：最小原生小程序

最小形态**只需两个文件**：一个页面、一个 manifest。现有小程序都已长成多文件结构，
下面的骨架可以直接照抄。

**1. 建页面** `lib/mini_apps/<name>/<name>_page.dart`：

```dart
import 'package:flutter/material.dart';

class MyPage extends StatelessWidget {
  const MyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的小程序')),
      body: const Center(child: Text('建设中')),
    );
  }
}
```

**2. 建 manifest** `lib/mini_apps/<name>/<name>_manifest.dart`：

```dart
import 'package:flutter/material.dart';

import '../../core/app_manifest.dart';
import 'my_page.dart';

/// 我的小程序的注册信息。
const myManifest = AppManifest(
  id: 'my-app',                    // 全注册表唯一
  label: '我的小程序',              // 宫格文字 + 页面顶栏标题
  color: Color(0xFF0082EF),        // 图标底色
  glyph: '我',                      // 底色上的单字；也可以用 icon: Icons.xxx
  entry: _myEntry,
);

// entry 用私有顶层函数包一层，而不是直接传 MyPage.new —— 这样 const 才成立。
Widget _myEntry(BuildContext context) => const MyPage();
```

**3. 登记** 到 `lib/mini_apps/registry.dart`：

```dart
final appRegistry = AppRegistry([
  bulletinManifest,
  electricityManifest,
  freeClassroomManifest,
  campusMapManifest,
  timetableManifest,
  myManifest,          // ← 加这一行
]);
```

完事，首页宫格自动多一个图标。

## 方式二：带网络请求的小程序

标准分层，参考 `lib/mini_apps/electricity/`（10 个文件）或 `free_classroom/`。
按顺序建：

| 步骤 | 文件 | 职责 |
|---|---|---|
| 1 | `<name>_models.dart` | 纯数据类 + `fromJson` / `toJson`。不 import flutter |
| 2 | `<name>_api.dart` | `class XxxApi`，全 `static`。发请求、解析响应、抛 `PortalException` |
| 3 | `<name>_store.dart` | `class XxxStore`，全 `static`。JSON 落盘缓存 |
| 4 | `<name>_controller.dart` | `ChangeNotifier` 单例 + `ensureStarted()`。串起 Store ↔ Api |
| 5 | `<name>_page.dart` | 详情页 |
| 6 | `<name>_manifest.dart` | `AppManifest` 常量 |
| 7 | `registry.dart` | 加一行 |

Controller 的标准骨架：

```dart
class MyController extends ChangeNotifier {
  MyController._();
  static final MyController instance = MyController._();

  bool _started = false;
  Future<void>? _starting;

  /// 幂等：重复调用会合流到同一次启动。
  Future<void> ensureStarted() {
    if (_started) return _starting ?? Future.value();
    _started = true;
    return _starting = _start();
  }
}
```

Store 的所有读写都要 `try/catch` 退化成「没有存储」—— widget 测试环境没有平台通道，
不这样做测试会挂。

## 方式三：H5 小程序

> ⚠️ **目前注册表里还没有任何 H5 实例**，这条路径的代码是齐的（`lib/mini_apps/web/mini_web_view_page.dart`
> 通用承载页），但缺少真实使用验证。第一个吃螃蟹的同学请把踩到的坑反馈到 Issue。

在注册表加一条带 `url` 的 `AppManifest` 即可，点击后由通用承载页打开：

```dart
AppManifest(
  id: 'demo-web',
  label: '网页示例',
  color: Color(0xFF8B5CF6),
  glyph: '网',
  url: 'https://example.com',
  // requiresPortal: true,   // 需要门户登录态时打开
),
```

可配置项只有 `url`（地址）、`label`（顶栏标题）和 `requiresPortal`。没有 UA 覆写、
没有 JS 注入白名单、没有 native bridge。

## 方式四：学习页卡片

学习页卡片与刷新回调在自己的 manifest 中一起声明，然后在 `registry.dart` 的
`AppRegistry([...])` 中登记一次。壳会自动展示卡片、按顺序排列并在下拉时刷新，不需要
修改学习页、刷新名单或路由表。

有详情页时使用普通 `AppManifest`。例如 `lib/mini_apps/score/score_manifest.dart`：

```dart
const scoreManifest = AppManifest(
  id: 'scores',
  label: '成绩查询',
  color: kScoreColor,
  icon: Icons.assessment_outlined,
  entry: _entry,
  showInHomeGrid: false,
  studyCard: StudyCardContribution(
    builder: _studyCard,
    order: 30,
    onRefresh: _studyRefresh,
  ),
);

Widget _entry(BuildContext context) => const ScorePage();
Widget _studyCard(BuildContext context) => const ScoreCard();
Future<void> _studyRefresh() => ScoreController.instance.refresh();
```

卡片内部使用 `context.push('/apps/scores')` 打开详情。`showInHomeGrid: false` 只隐藏宫格
入口，详情页仍可通过注册表访问；如果也需要宫格入口，保留默认的 `true`。

没有详情页时使用 `AppManifest.cardOnly`，只需填写 `id`、`label`、`studyCard` 三项。
参考 `lib/mini_apps/student_info/student_info_manifest.dart` 或
`lib/mini_apps/academic/academic_manifest.dart`：这类模块不提供 `entry/url` 或图标配置，
不会出现在宫格中，也没有 `/apps/<id>` 入口。

学习卡片的约定：

- `builder` 和 `order` 必填，`onRefresh` 可选；静态卡片无需提供刷新回调。
- `order` 越小越靠前，同值时按模块 id 排序，与首页宫格顺序无关。现有五张卡依次使用
  10、20、30、40、50，方便在中间插入卡片。
- 卡片挂载时自行调用 Controller 的 `ensureStarted()`；注册表只保存描述，不预加载数据。
- 下拉刷新并发调用当前注册卡片的 `onRefresh` 并等待全部完成。回调通过 `Future.sync`
  包装，单项同步抛错不会阻止其他项启动；各模块应自行处理业务错误并在卡片里展示。
- 卡片与详情页共用 Controller 单例，点击是否可用也由卡片自行判断。

## 取用门户登录态

需要教务、电费这类登录后才能访问的接口时，**不要自己搓登录流程**，用
`lib/core/auth/portal_session.dart` 的全局会话。细节见 [统一门户登录](portal-auth.md)。

原生小程序：

```dart
final response = await PortalSession.instance.request(
  PortalServices.jwxt,                    // CAS 的 service 参数
  (http) => http.get(Uri.parse('https://${CampusHosts.jwxt}/...')),
);
```

> 校内主机名一律从 `lib/core/config/campus_config.dart` 的 `CampusHosts` 派生，
> 不要硬编码域名；真实根域 hex 编码存放在 `campus_config.dart`，见 [校园地址与密钥](configuration.md)。

> **⚠️ `request` 的 `send` 回调可能被调用两次** —— 会话失效时会自动重登并重放。
> 别在回调里放有副作用的逻辑。

H5 小程序：在注册表那条 `AppManifest` 上加 `requiresPortal: true`，承载页会先把会话
Cookie 灌进 WebView 再加载页面，网页里直接就是登录态。

**务必区分两类失败**（`PortalException` 的子类）：

- `PortalNetworkError` —— 网络问题，可重试
- `PortalCredentialError` —— 通行密钥被吊销，需要引导用户重新绑定
- `PortalLoginError` —— 其他登录失败

把「没网」说成「需要重新绑定」，会让用户白跑一趟去重绑。

## 检查清单

提交前过一遍：

- [ ] `id` 在注册表里唯一，包括仅卡片模块（`AppRegistry` 构造时会拒绝重复 id）
- [ ] `label` **不与现有小程序重名**（否则 `widget_test.dart` 的 `findsOneWidget` 断言会挂）
- [ ] 普通 manifest 的 `entry` 与 `url` 恰好提供一个；没有详情页的学习卡片使用 `AppManifest.cardOnly`
- [ ] `mini_apps/<name>/` 没有 import `shell/*` 或兄弟小程序
- [ ] Store 的读写都有 `try/catch` 兜底
- [ ] 有解析逻辑的话补上单元测试（参考 `test/free_classroom_models_test.dart`）
- [ ] 学习页卡片已声明 `studyCard` 的构建、顺序与所需刷新回调，且已在唯一注册表中登记
- [ ] 有详情页时，卡片内部使用 `context.push('/apps/<id>')` 跳转
