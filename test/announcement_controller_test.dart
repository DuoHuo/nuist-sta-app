// 公告 controller：条件请求、304、失败回退、红点、已读、不可关闭保护。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/network/client_metadata.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_api.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_controller.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_models.dart';

const currentMetadata = ClientMetadata(
  platform: 'android',
  appPackage: 'dev.duohuo.nuist_sta_app',
  appChannel: 'release',
  appVersion: '0.2.8',
  appVersionCode: 2800,
);

Announcement a(
  String id, {
  AnnouncementRemind remind = AnnouncementRemind.none,
  bool dismissible = true,
  DateTime? expiresAt,
}) => Announcement(
  id: id,
  title: '标题$id',
  remind: remind,
  dismissible: dismissible,
  expiresAt: expiresAt,
);

class Harness {
  Harness({
    this.cache,
    Set<String>? readIds,
    AnnouncementFetchResult Function()? respond,
    this.metadata = currentMetadata,
    this.metadataProvider,
  }) : readIds = readIds ?? <String>{},
       respond =
           respond ??
           (() => AnnouncementFetchResult(
             notModified: cache != null,
             items: cache == null ? const [] : null,
           ));

  AnnouncementCache? cache;
  Set<String> readIds;
  AnnouncementFetchResult Function() respond;
  final ClientMetadata metadata;
  final Future<ClientMetadata> Function()? metadataProvider;
  DateTime clock = DateTime.utc(2026, 1, 1);
  final calls = <(String?, String?)>[];

  late final controller = AnnouncementController.test(
    fetch: ({etag, lastModified}) async {
      calls.add((etag, lastModified));
      return respond();
    },
    readCache: () async => cache,
    saveCache: (c) async => cache = c,
    readReadIds: () async => readIds,
    saveReadIds: (ids) async => readIds = ids,
    now: () => clock,
    metadataProvider: metadataProvider ?? (() async => metadata),
  );
}

AnnouncementCache cacheOf(
  List<Announcement> items, {
  ClientMetadata metadata = currentMetadata,
}) => AnnouncementCache(
  items: items,
  cacheKey: metadata.cacheKey,
  etag: '"e"',
  lastModified: 'LM',
  fetchedAt: DateTime.utc(2025),
);

void main() {
  test('有缓存时带条件头，304 复用缓存', () async {
    final h = Harness(cache: cacheOf([a('1')]));
    await h.controller.ensureStarted();
    expect(h.calls.single, ('"e"', 'LM'));
    expect(h.controller.visible.map((x) => x.id), ['1']);
    expect(h.cache!.fetchedAt, h.clock);
  });

  test('无缓存（或缓存损坏读出 null）时不带条件头', () async {
    final h = Harness(
      respond: () => AnnouncementFetchResult(
        notModified: false,
        items: [a('n')],
        etag: '"x"',
      ),
    );
    await h.controller.ensureStarted();
    expect(h.calls.single, (null, null));
    expect(h.controller.visible.single.id, 'n');
    expect(h.cache!.etag, '"x"');
  });

  test('拉取失败静默保留缓存；无缓存时为空且不抛', () async {
    final h = Harness(
      cache: cacheOf([a('1')]),
      respond: () => throw Exception('net'),
    );
    await h.controller.ensureStarted();
    expect(h.controller.visible.single.id, '1');
    final empty = Harness(respond: () => throw Exception('net'));
    await empty.controller.ensureStarted();
    expect(empty.controller.visible, isEmpty);
    expect(empty.controller.hasUnread, isFalse);
  });

  test('ensureStarted 幂等', () async {
    final h = Harness();
    await Future.wait([
      h.controller.ensureStarted(),
      h.controller.ensureStarted(),
    ]);
    await h.controller.ensureStarted();
    expect(h.calls, hasLength(1));
  });

  for (final r in AnnouncementRemind.values) {
    test('红点：remind=${r.name} 未读时亮，全部已读后灭', () async {
      final h = Harness(cache: cacheOf([a('1', remind: r)]));
      await h.controller.ensureStarted();
      expect(h.controller.hasUnread, isTrue);
      await h.controller.markAllVisibleRead();
      expect(h.controller.hasUnread, isFalse);
      expect(h.readIds, {'1'});
    });
  }

  test('markRead 只影响给定 id；分类列表排除已读', () async {
    final h = Harness(
      cache: cacheOf([
        a('b', remind: AnnouncementRemind.badge),
        a('p', remind: AnnouncementRemind.popup),
      ]),
    );
    await h.controller.ensureStarted();
    expect(h.controller.unreadBadge.single.id, 'b');
    expect(h.controller.unreadPopup.single.id, 'p');
    await h.controller.markRead(['p']);
    expect(h.controller.unreadPopup, isEmpty);
    expect(h.controller.unreadBadge.single.id, 'b');
    expect(h.controller.hasUnread, isTrue);
  });

  test('筛选后的列表不清理其他版本的已读标记', () async {
    final h = Harness(
      readIds: {'1', 'gone'},
      respond: () =>
          AnnouncementFetchResult(notModified: false, items: [a('1')]),
    );
    await h.controller.ensureStarted();
    expect(h.readIds, {'1', 'gone'});
    expect(h.controller.hasUnread, isFalse);
  });

  test('取得客户端上下文前不读取或展示缓存', () async {
    final metadata = Completer<ClientMetadata>();
    var cacheReads = 0;
    final c = AnnouncementController.test(
      metadataProvider: () => metadata.future,
      readCache: () async {
        cacheReads++;
        return cacheOf([a('cached')]);
      },
      fetch: ({etag, lastModified}) async =>
          const AnnouncementFetchResult(notModified: true),
    );
    addTearDown(c.dispose);
    final started = c.ensureStarted();
    await Future<void>.delayed(Duration.zero);
    expect(cacheReads, 0);
    expect(c.visible, isEmpty);
    metadata.complete(currentMetadata);
    await started;
    expect(cacheReads, 1);
    expect(c.visible.single.id, 'cached');
  });

  for (final scenario in [
    (
      name: '升级版本',
      metadata: const ClientMetadata(
        platform: 'android',
        appPackage: 'dev.duohuo.nuist_sta_app',
        appChannel: 'release',
        appVersion: '0.2.9',
        appVersionCode: 2900,
      ),
    ),
    (
      name: '更换包名',
      metadata: const ClientMetadata(
        platform: 'android',
        appPackage: 'dev.duohuo.nuist_sta_app.debug',
        appChannel: 'release',
        appVersion: '0.2.8',
        appVersionCode: 2800,
      ),
    ),
    (
      name: '更换渠道',
      metadata: const ClientMetadata(
        platform: 'android',
        appPackage: 'dev.duohuo.nuist_sta_app',
        appChannel: 'ci',
        appVersion: '0.2.8',
        appVersionCode: 2800,
      ),
    ),
  ]) {
    test('${scenario.name}后离线不展示旧公告，也不发送旧条件头', () async {
      final stored = cacheOf([
        a('old', dismissible: false, expiresAt: DateTime.utc(2030)),
      ]);
      final h = Harness(
        cache: stored,
        metadata: scenario.metadata,
        readIds: {'old'},
        respond: () => throw Exception('offline'),
      );
      await h.controller.ensureStarted();
      expect(h.calls.single, (null, null));
      expect(h.controller.visible, isEmpty);
      expect(h.controller.blocking, isEmpty);
      expect(h.cache, same(stored));
      expect(h.readIds, {'old'});
    });
  }

  test('旧格式缓存失效，新响应覆盖缓存但保留已读状态', () async {
    final old = cacheOf([a('same')]).toJson()
      ..remove('schemaVersion')
      ..remove('cacheKey');
    final h = Harness(
      cache: AnnouncementCache.fromJson(old),
      readIds: {'same', 'another-version'},
      respond: () => AnnouncementFetchResult(
        notModified: false,
        items: [a('same', remind: AnnouncementRemind.popup)],
        etag: '"new"',
      ),
    );
    await h.controller.ensureStarted();
    expect(h.calls.single, (null, null));
    expect(h.cache!.matches(currentMetadata.cacheKey), isTrue);
    expect(h.cache!.etag, '"new"');
    expect(h.controller.unreadPopup, isEmpty);
    expect(h.readIds, {'same', 'another-version'});
  });

  for (final failProvider in [false, true]) {
    test('${failProvider ? '读取元数据失败' : '版本号缺失'}仍请求新公告，不复用或覆盖缓存', () async {
      final stored = cacheOf([a('old')]);
      final h = Harness(
        cache: stored,
        metadata: const ClientMetadata(
          platform: 'android',
          appPackage: 'dev.duohuo.nuist_sta_app',
          appChannel: 'release',
          appVersion: '0.2.8',
        ),
        metadataProvider: failProvider
            ? () async => throw Exception('metadata unavailable')
            : null,
        respond: () => AnnouncementFetchResult(
          notModified: false,
          items: [a('universal')],
        ),
      );
      await h.controller.ensureStarted();
      expect(h.calls.single, (null, null));
      expect(h.controller.visible.single.id, 'universal');
      expect(h.cache, same(stored));
    });
  }

  test('无缓存收到 304 时补一次无条件请求并使用新响应', () async {
    var count = 0;
    final h = Harness(
      respond: () => ++count == 1
          ? const AnnouncementFetchResult(notModified: true)
          : AnnouncementFetchResult(notModified: false, items: [a('new')]),
    );
    await h.controller.ensureStarted();
    expect(h.calls, [(null, null), (null, null)]);
    expect(h.controller.visible.single.id, 'new');
    expect(h.cache!.matches(currentMetadata.cacheKey), isTrue);
  });

  test('无缓存连续收到 304 时停止重试，不生成成功缓存', () async {
    final h = Harness(
      respond: () => const AnnouncementFetchResult(notModified: true),
    );
    await h.controller.ensureStarted();
    expect(h.calls, [(null, null), (null, null)]);
    expect(h.controller.visible, isEmpty);
    expect(h.cache, isNull);
  });

  group('不可关闭保护', () {
    test('无 expiresAt 视为可关闭', () async {
      final h = Harness(
        cache: cacheOf([
          a('x', dismissible: false, remind: AnnouncementRemind.popup),
        ]),
      );
      await h.controller.ensureStarted();
      expect(h.controller.blocking, isEmpty);
      expect(h.controller.unreadPopup.single.id, 'x');
    });

    test('已读不压制；本地时间过期即释放', () async {
      final h = Harness(
        respond: () => throw Exception('offline'),
        cache: cacheOf([
          a('x', dismissible: false, expiresAt: DateTime.utc(2026, 1, 2)),
        ]),
      );
      await h.controller.ensureStarted();
      await h.controller.markAllVisibleRead();
      expect(h.controller.blocking.single.id, 'x');
      expect(h.controller.nextExpiry, const Duration(days: 1));
      h.clock = DateTime.utc(2026, 1, 3);
      expect(h.controller.blocking, isEmpty);
      expect(h.controller.nextExpiry, isNull);
    });

    test('服务器列表移除后从缓存清除', () async {
      final h = Harness(
        cache: cacheOf([
          a('x', dismissible: false, expiresAt: DateTime.utc(2030)),
        ]),
        respond: () =>
            AnnouncementFetchResult(notModified: false, items: [a('y')]),
      );
      await h.controller.ensureStarted();
      expect(h.controller.blocking, isEmpty);
      expect(h.cache!.items.map((x) => x.id), ['y']);
    });
  });
}
