# nuist-sta-app

NUIST赛博分院帽 - 众社团共建

## 当前进度

- [x] 首页框架（Flutter，Android 优先）
  - 顶栏居中标题（`APP名称` 为占位，定稿后改 `lib/main.dart` 里的 `kAppName` 一处即可）
  - 应用宫格卡片，数据驱动、可扩展：新增应用只需在 `HomePage.apps` 加一条 `AppItem`
  - 底部双页签：首页 / 我的
- [ ] 校园地图页面
- [ ] 我的页面
- [ ] 分院帽测试等社团功能

## 如何运行

```bash
flutter pub get
flutter run          # 连接设备或模拟器
flutter test         # 运行测试
flutter build apk    # 构建 release APK
```

> 注意：Dart 分析服务器对含中文/OneDrive 同步目录的路径支持不佳，
> 建议将仓库克隆到纯英文本地路径（如 `C:\dev\nuist-sta-app`）再开发。

## 设计稿

`design/home.op` 为首页设计稿（OpenPencil 格式）。
