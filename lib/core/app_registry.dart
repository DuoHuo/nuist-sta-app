import 'app_manifest.dart';
import 'logging/app_log.dart';

/// 从一份小程序声明派生首页宫格、学习卡片与可访问的全屏入口。
class AppRegistry {
  static final _log = AppLog.logger('core.app_registry');

  /// 校验所有模块的 id 唯一，并生成不可修改的展示列表与路由索引。
  factory AppRegistry(Iterable<AppManifest> manifests) {
    final apps = List<AppManifest>.unmodifiable(manifests);
    final ids = <String>{};
    for (final app in apps) {
      if (!ids.add(app.id)) {
        throw ArgumentError.value(app.id, 'manifests', '小程序 id 重复');
      }
    }
    final studyApps = apps.where((app) => app.studyCard != null).toList()
      ..sort((a, b) {
        final order = a.studyCard!.order.compareTo(b.studyCard!.order);
        return order == 0 ? a.id.compareTo(b.id) : order;
      });
    return AppRegistry._(
      apps: apps,
      homeGridApps: List<AppManifest>.unmodifiable(
        apps.where((app) => app.showInHomeGrid),
      ),
      studyApps: List<AppManifest>.unmodifiable(studyApps),
      byId: Map<String, AppManifest>.unmodifiable({
        for (final app in apps)
          if (app.hasEntry) app.id: app,
      }),
    );
  }

  const AppRegistry._({
    required this.apps,
    required this.homeGridApps,
    required this.studyApps,
    required this.byId,
  });

  /// 全量注册声明，保留登记顺序。
  final List<AppManifest> apps;

  /// 首页宫格入口，保留登记顺序。
  final List<AppManifest> homeGridApps;

  /// 提供学习卡片的模块，按卡片顺序、模块 id 排列。
  final List<AppManifest> studyApps;

  /// 有全屏入口的模块索引；仅卡片模块不占用 `/apps/:appId` 入口。
  final Map<String, AppManifest> byId;

  /// 通知所有模块本机门户绑定已变化，等待处理完成后返回是否全部无异常。
  ///
  /// 显式绑定回调优先；未提供时复用已有卡片的刷新，同一模块共用的回调只调用
  /// 一次。各回调并发启动，单项同步或异步异常不会阻断其他模块的处理。
  Future<bool> notifyPortalBindingChanged({required bool bound}) async {
    final pending = <Future<bool>>[];
    for (final app in apps) {
      final handler = app.onPortalBindingChanged;
      final callbacks = handler != null
          ? <Future<void> Function()>[() => handler(bound)]
          : <Future<void> Function()>{
              if (app.homeCard != null) ?app.onHomeRefresh,
              ?app.studyCard?.onRefresh,
            };
      for (final callback in callbacks) {
        pending.add(
          Future<void>.sync(callback).then(
            (_) => true,
            onError: (Object error, StackTrace stack) {
              _log.warning(
                'portal_binding.notify_failed',
                fields: {'app_id': app.id},
                error: error,
                stackTrace: stack,
              );
              return false;
            },
          ),
        );
      }
    }
    return (await Future.wait(pending)).every((success) => success);
  }
}
