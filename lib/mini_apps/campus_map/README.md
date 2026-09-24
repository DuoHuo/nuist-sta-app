# 校园地图前端

Flutter + MapLibre 原生子程序。首页入口已注入 `CampusMapApi`，默认连接 `http://202.195.237.186:12345`。

## 服务器连接

API 使用 `http://202.195.237.186:12345/api/v1`。瓦片与样式统一走 API 同源代理 `/martin/*`（后端 `CAMPUS_MARTIN_UPSTREAM` 指向 martin 容器），因为真机网络普遍放行 API 端口、而 Martin 独立端口 30000 会被防火墙重置（真机浏览器实测 ERR_CONNECTION_RESET）。客户端把旧式 `localhost:3000`、独立 30000 端口以及遗漏代理前缀的地址统一归一到 `{API}/martin/*`，并保留 TileJSON 的 minzoom/maxzoom/bounds/attribution（maxzoom=14 时由 MapLibre 放大渲染第 14 级瓦片）。该方案依赖后端重新部署后的 `/martin` 代理；旧版线上服务没有该路由，样式加载会按设计降级为提示。

MBTiles 已就绪。公网联调已下载并验证 23,751 字节的真实矢量瓦片。域名自定义端口仍受代理连通性影响，当前使用已验证可用的 IP。后端仓库 Compose 与样式 URL 已修复，但没有远程部署权限配置，运行中的服务器未被重启或修改；客户端兼容旧线上配置。

## 本地测试连接

```bash
adb reverse tcp:8080 tcp:8080
# Martin 启动后需同时转发瓦片端口
adb reverse tcp:3000 tcp:3000
flutter run --dart-define=CAMPUS_API_BASE_URL=http://127.0.0.1:8080
```

本地回归测试可显式覆盖 API 地址。Android debug 额外允许上述回环测试地址的 HTTP，release 仅允许服务器域名和指定服务器 IP。手机的回环地址指向手机自身，本地调试需要端口转发。地图配置中的瓦片、字形、精灵、样式地址同样必须可达。

## 实际接口

契约来自同目录后端仓库的 `internal/modules/mapdata`、`routing`、`locate`。

| 功能 | 接口 |
| --- | --- |
| 地图配置 | `GET /api/v1/map/config` |
| 建筑列表、搜索 | `GET /api/v1/buildings?q=` |
| 建筑详情、楼层与入口 | `GET /api/v1/buildings/:id`，响应自带 floors/entrances |
| 建筑轮廓 | `GET /api/v1/buildings/:id/geometry` |
| 室内要素 | `GET /api/v1/floors/:floorId/features` |
| 地点搜索、详情 | `GET /api/v1/pois`、`GET /api/v1/pois/:id` |
| 通用地物列表、详情 | `GET /api/v1/features`、`GET /api/v1/features/:id` |
| 路线 | `POST /api/v1/route` |
| Wi-Fi 定位适配 | `POST /api/v1/locate/wifi` |
| 指纹查询、采集适配 | `GET/POST /api/v1/fingerprints`，写入支持 `X-Collect-Token` |

几何接口解析原始 GeoJSON，其余解析 `{code,message,data}`。建筑轮廓最大并发六个；详情按选择加载。搜索去抖并忽略过期响应。指纹与定位接口已封装数据访问，没有新增采集管理页面或手机扫描功能，不自动发送观测或写入指纹。

## 数据和显示边界

- 户外底图（道路、水系、建筑、绿地与标注）来自 Martin 样式，程序不叠加业务建筑填充或 POI 圆点；
  **通用地物是例外**：管理台提交的道路/绿地/广场等由 App 自绘（`campus-features-*` 图层：面填充、线描边、点圆）。
  底图瓦片是派生产物，新提交的地物不会立刻进瓦片，而提交随时在发生——自绘让「提交后 App 立刻可见」，不必等重新切片。
- 三类地物各有稳定编号：建筑 `building_id`、地点 `poi_id`、通用地物 `feature_id`；点击命中顺序为
  「房间 → 建筑 → 通用地物 → 街景」，命中后先开面板，面板上的「查看详情」进入统一详情页。
  详情路由 `/place/:placeId` 可深链可分享，页面按编号自行取数，不依赖地图页是否打开。
  注意：只存在于 OSM 瓦片、没有业务编号的底图要素仍然点不开——要让某类地物有详情页，得先在管理台把它提交进库。
- 底图标签与管理台保持一致：中文优先取 `name:nonlatin` → `name` → `name:latin`；楼名用业务库中的命名建筑注入蓝色标注层（`#16307A`，minzoom 15.5，随缩放放大），并排除底图 POI 中重名的文字，避免同楼两份名字。
- 楼宇轮廓以近乎全透明图层（`fillOpacity 0.01`）挂载，**只作点击命中区域**，不改变地图外观；点击命中后按业务 `building_id` 打开该楼详情面板。
- `featureTapsTriggersMapClick` 必须为 true：插件默认在点击落到可交互图层时不回调 `onMapClick`，否则点楼无响应。命中选择按图层分别查询（房间 → 建筑 → 街景），因为插件返回的 Feature 不携带图层 id。
- 瓦片最高层级为 14，放大到更高层级由 MapLibre 过采样第 14 级瓦片，属于预期表现。
- 优先后端 `style_url`；为空时按 `configs/style.demo.json` 的图层规则构造基础样式。瓦片、字形、精灵地址来自真实配置并统一归一到 API 同源 `/martin/*` 代理（Martin 独立端口在真机网络会被防火墙重置）。
- Sprite/字形不可达时自动降级丢弃（最多丢文字，不影响底图主体）。
- 建筑质心仅用于视角；路线使用真实入口、节点或 POI。缺少入口时明确提示，不把质心当入口。
- 没有分类的建筑保留未分类，不按名字猜测。楼层 id、显示名、排序、导航层号分开，不推算楼层名称。
- 房间导航需要明确的 `poi_id` 或 `nav_node_id`，不按名字猜测、不穿墙画线。
- 墙体只在实际 `kind=wall` 多边形提供 `height_m` 时拉伸；房间、走廊保持开放顶面。适配器附加请求上下文中的楼宇和楼层 id，路线按后端分段显示。
- 后端目前仅预留 `splat_scene_id`，没有街景覆盖/场景下载接口，街景保持占位，不生成覆盖点或初始化三维引擎。
- 当前真实数据库没有室内楼层和指纹记录，保持空状态，不运行种子数据、不写测试指纹。

## 验证

```bash
flutter test test/campus_map_api_test.dart test/campus_map_test.dart test/widget_test.dart
flutter test --dart-define=CAMPUS_LIVE_TEST=true test/campus_map_live_test.dart
```

此前本地真实接口联调读取到 248 栋建筑、25 个 POI、248 个轮廓；搜索、详情成功，poi:8 至 poi:18 返回 989.2 米路线，指纹查询为空。Live 测试默认跳过，开启后仍不写后端。真实室内效果需实际数据，原生底图效果需 Martin 和移动设备验证。

独立 `CampusMapPage()` 仍默认空数据源，方便组件测试；实际首页入口通过 `campus_map_manifest.dart` 注入真实 API。
