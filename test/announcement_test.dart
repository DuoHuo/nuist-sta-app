// 公告接口、模型与控制器单元测试。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/config/api_endpoints.dart';
import 'package:nuist_sta_app/core/network/client_metadata.dart';
import 'package:nuist_sta_app/core/privacy/privacy_consent.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_api.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_controller.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_models.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_overlay.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_store.dart';

class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);
  final ResponseBody Function(RequestOptions) handler;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody json(
  Object body, {
  Map<String, List<String>> headers = const {},
}) => ResponseBody.fromString(
  jsonEncode(body),
  200,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
    ...headers,
  },
);

(AnnouncementApi, FakeAdapter) build(ResponseBody Function(RequestOptions) h) {
  final adapter = FakeAdapter(h);
  final dio = Dio()..httpClientAdapter = adapter;
  return (AnnouncementApi(dio: dio), adapter);
}

Map<String, dynamic> item(String id, [Map<String, dynamic> extra = const {}]) =>
    {'id': id, 'title': '标题$id', ...extra};

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
  String summary = '',
  String content = '',
}) => Announcement(
  id: id,
  title: '标题$id',
  summary: summary.isEmpty ? '摘要$id' : summary,
  content: content,
  remind: remind,
  dismissible: dismissible,
  expiresAt: expiresAt,
);

Widget _overlayApp(AnnouncementController c) => MaterialApp(
  home: Scaffold(
    appBar: AppBar(actions: [AnnouncementBell(controller: c)]),
    body: AnnouncementOverlay(controller: c, child: const SizedBox.expand()),
  ),
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
  group('AnnouncementApi', () {
    test('200 解析并读出 etag / last-modified，无参数时不带条件头', () async {
      final (api, adapter) = build(
        (_) => json(
          {
            'version': 1,
            'items': [
              {'id': '1', 'title': 't'},
            ],
          },
          headers: {
            'etag': ['"v1"'],
            'last-modified': ['Wed, 01 Jan 2026 00:00:00 GMT'],
          },
        ),
      );
      final r = await api.fetch();
      expect(r.notModified, isFalse);
      expect(r.items, hasLength(1));
      expect(r.etag, '"v1"');
      expect(r.lastModified, 'Wed, 01 Jan 2026 00:00:00 GMT');
      final req = adapter.requests.single;
      expect(req.uri.toString(), kAnnouncementEndpoint);
      expect(req.method, 'GET');
      final keys = req.headers.keys.map((k) => k.toLowerCase()).toSet();
      expect(keys.contains('if-none-match'), isFalse);
      expect(keys.contains('if-modified-since'), isFalse);
      expect(keys.contains('authorization'), isFalse);
      expect(keys.contains('cookie'), isFalse);
    });

    test('有校验值时发条件头；304 返回 notModified 且不抛', () async {
      final (api, adapter) = build((_) => ResponseBody.fromString('', 304));
      final r = await api.fetch(etag: '"v1"', lastModified: 'LM');
      expect(r.notModified, isTrue);
      expect(r.items, isNull);
      final req = adapter.requests.single;
      expect(req.headers['If-None-Match'], '"v1"');
      expect(req.headers['If-Modified-Since'], 'LM');
    });

    test('items 不是数组抛 FormatException', () async {
      final (api, _) = build((_) => json({'items': 'x'}));
      expect(api.fetch(), throwsFormatException);
    });

    test('5xx 抛出', () async {
      final (api, _) = build((_) => ResponseBody.fromString('', 500));
      expect(api.fetch(), throwsA(isA<DioException>()));
    });

    test('关闭 API 不关闭外部注入的客户端', () async {
      final (api, _) = build((_) => json({'items': []}));
      api.close();
      final result = await api.fetch();
      expect(result.notModified, isFalse);
      expect(result.items, isEmpty);
    });
  });

  group('AnnouncementModels', () {
    test('忽略未知字段，畸形项跳过而其余保留', () {
      final list = parseAnnouncementResponse({
        'version': 1,
        'extra': true,
        'items': [
          item('a', {'foo': 'bar'}),
          {'title': '缺 id'},
          {'id': 'x'},
          {'id': '', 'title': '空 id'},
          'not a map',
          42,
          item('b'),
          item('a'),
        ],
      });
      expect(list.map((a) => a.id), ['a', 'b']);
    });

    test('支持 JSON 字符串；items 不是数组抛 FormatException', () {
      expect(
        parseAnnouncementResponse('{"items":[{"id":"1","title":"t"}]}'),
        hasLength(1),
      );
      expect(
        () => parseAnnouncementResponse({'items': {}}),
        throwsFormatException,
      );
      expect(() => parseAnnouncementResponse(null), throwsFormatException);
    });

    test('未知枚举退化，缺 dismissible 为 true，非 https 链接丢弃', () {
      final a = Announcement.tryParse(
        item('a', {
          'remind': 'urgent',
          'tone': 'scary',
          'link': {'label': 'x', 'url': 'http://example.com'},
        }),
      )!;
      expect(a.remind, AnnouncementRemind.none);
      expect(a.tone, AnnouncementTone.normal);
      expect(a.dismissible, isTrue);
      expect(a.link, isNull);
      final b = Announcement.tryParse(
        item('b', {
          'remind': 'popup',
          'tone': 'alert',
          'link': {'label': '看看', 'url': 'https://example.com/a'},
        }),
      )!;
      expect(b.remind, AnnouncementRemind.popup);
      expect(b.tone, AnnouncementTone.alert);
      expect(b.link!.url, 'https://example.com/a');
    });

    test('只过滤过期公告，旧版本区间字段不再参与客户端判断', () {
      final now = DateTime.utc(2026, 1, 1);
      final all = [
        Announcement.tryParse(
          item('old', {'expiresAt': '2025-12-31T00:00:00Z'}),
        )!,
        Announcement.tryParse(item('ok'))!,
        Announcement.tryParse(item('min', {'minAppVersion': '1.2'}))!,
        Announcement.tryParse(item('max', {'maxAppVersion': '1.9.0'}))!,
        Announcement.tryParse(
          item('eq', {'minAppVersion': '1.10.0', 'maxAppVersion': '1.10'}),
        )!,
      ];
      final ids = visibleAnnouncements(all, now: now).map((a) => a.id).toSet();
      expect(ids, {'ok', 'min', 'max', 'eq'});
      for (final announcement in all) {
        expect(announcement.toJson(), isNot(contains('minAppVersion')));
        expect(announcement.toJson(), isNot(contains('maxAppVersion')));
      }
    });

    test('置顶优先，再按发布时间降序', () {
      final all = [
        Announcement.tryParse(
          item('a', {'publishedAt': '2026-01-01T00:00:00Z'}),
        )!,
        Announcement.tryParse(
          item('b', {'publishedAt': '2026-03-01T00:00:00Z'}),
        )!,
        Announcement.tryParse(
          item('p', {'pinned': true, 'publishedAt': '2025-01-01T00:00:00Z'}),
        )!,
        Announcement.tryParse(item('n'))!,
      ];
      final ids = visibleAnnouncements(
        all,
        now: DateTime.utc(2026, 6),
      ).map((a) => a.id);
      expect(ids, ['p', 'b', 'a', 'n']);
    });

    test('超过 50 条截断', () {
      final list = parseAnnouncementResponse({
        'items': [for (var i = 0; i < 60; i++) item('$i')],
      });
      expect(list, hasLength(kMaxAnnouncements));
    });

    test('缓存 toJson/fromJson 往返一致', () {
      final items = parseAnnouncementResponse({
        'items': [
          item('a', {
            'summary': 's',
            'content': 'c\nd',
            'publishedAt': '2026-01-01T00:00:00.000Z',
            'expiresAt': '2026-02-01T00:00:00.000Z',
            'pinned': true,
            'remind': 'badge',
            'dismissible': false,
            'tone': 'notice',
            'minAppVersion': '0.1.0',
            'link': {'label': 'l', 'url': 'https://e.com'},
          }),
        ],
      });
      final cache = AnnouncementCache(
        items: items,
        cacheKey: 'current-context',
        etag: '"e"',
        lastModified: 'Wed, 01 Jan 2026 00:00:00 GMT',
        fetchedAt: DateTime.utc(2026, 1, 2),
      );
      final back = AnnouncementCache.fromJson(cache.toJson());
      expect(back.toJson(), cache.toJson());
      expect(back.matches('current-context'), isTrue);
      expect(back.matches('different-context'), isFalse);
      expect(back.matches(null), isFalse);
      expect(() => AnnouncementCache.fromJson({'x': 1}), throwsFormatException);
    });

    test('旧缓存和未知格式均不能复用，即使条目与校验头仍能解析', () {
      final old = {
        'items': [item('old')],
        'etag': '"old"',
        'fetchedAt': '2026-01-01T00:00:00Z',
      };
      final legacy = AnnouncementCache.fromJson(old);
      expect(legacy.items.single.id, 'old');
      expect(legacy.matches('current-context'), isFalse);
      final future = AnnouncementCache.fromJson({
        ...old,
        'schemaVersion': AnnouncementCache.currentSchemaVersion + 1,
        'cacheKey': 'current-context',
      });
      expect(future.matches('current-context'), isFalse);
    });
  });

  group('AnnouncementController', () {
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

    test('客户端上下文变化后离线不展示旧公告，也不发送旧条件头', () async {
      final stored = cacheOf([
        a('old', dismissible: false, expiresAt: DateTime.utc(2030)),
      ]);
      final h = Harness(
        cache: stored,
        metadata: const ClientMetadata(
          platform: 'android',
          appPackage: 'dev.duohuo.nuist_sta_app',
          appChannel: 'release',
          appVersion: '0.2.9',
          appVersionCode: 2900,
        ),
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
      test('不可关闭但无 expiresAt 视为可关闭，有 expiresAt 才阻断', () async {
        final noExpiry = Announcement.tryParse(
          item('a', {'dismissible': false}),
        )!;
        final withExpiry = Announcement.tryParse(
          item('b', {
            'dismissible': false,
            'expiresAt': '2030-01-01T00:00:00Z',
          }),
        )!;
        expect(noExpiry.blocking, isFalse);
        expect(withExpiry.blocking, isTrue);

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

    test('启动读盘完成前调用 markRead，合并持久化已读集合时不丢失内存已读项', () async {
      final readCompleter = Completer<Set<String>>();
      Set<String> saved = {};
      final c = AnnouncementController.test(
        metadataProvider: () async => currentMetadata,
        readReadIds: () => readCompleter.future,
        saveReadIds: (ids) async => saved = ids,
        fetch: ({etag, lastModified}) async => AnnouncementFetchResult(
          notModified: false,
          items: [
            a('early', remind: AnnouncementRemind.badge),
            a('stored', remind: AnnouncementRemind.badge),
            a('fresh', remind: AnnouncementRemind.badge),
          ],
        ),
      );
      addTearDown(c.dispose);
      final started = c.ensureStarted();
      await Future<void>.delayed(Duration.zero);
      await c.markRead(['early']);
      readCompleter.complete({'stored'});
      await started;
      expect(c.unreadBadge.map((x) => x.id), ['fresh']);
      expect(saved, containsAll(['early', 'stored']));
    });

    test('AnnouncementStore.saveReadIds 并发调用在无存储环境下安全顺序结束', () async {
      await Future.wait([
        AnnouncementStore.saveReadIds({'a'}),
        AnnouncementStore.saveReadIds({'a', 'b'}),
      ]);
    });
  });

  group('AnnouncementOverlay UI 门禁', () {
    testWidgets('PrivacyConsent.dialogPending 为 true 时推迟公告弹出与悬浮条，复位后正常展示', (
      tester,
    ) async {
      PrivacyConsent.dialogPending.value = true;
      addTearDown(() => PrivacyConsent.dialogPending.value = false);
      final c = AnnouncementController.test(
        fetch: ({etag, lastModified}) async => AnnouncementFetchResult(
          notModified: false,
          items: [
            a('p', remind: AnnouncementRemind.popup),
            a('b', remind: AnnouncementRemind.badge),
          ],
        ),
        now: () => DateTime.utc(2026, 1, 1),
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(_overlayApp(c));
      await tester.pumpAndSettle();
      expect(find.text('标题p'), findsNothing);
      expect(find.text('标题b'), findsNothing);

      PrivacyConsent.dialogPending.value = false;
      await tester.pumpAndSettle();
      expect(find.text('标题p'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(find.text('标题b'), findsOneWidget);
    });

    testWidgets('不可关闭弹窗无关闭按钮、拦截返回，过期后释放并接着弹未读 popup', (tester) async {
      var clock = DateTime.utc(2026, 1, 1);
      final c = AnnouncementController.test(
        fetch: ({etag, lastModified}) async => AnnouncementFetchResult(
          notModified: false,
          items: [
            a(
              'x',
              dismissible: false,
              expiresAt: DateTime.utc(2026, 1, 1, 0, 1),
              content: '维护中',
            ),
            a('p', remind: AnnouncementRemind.popup),
          ],
        ),
        now: () => clock,
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(_overlayApp(c));
      await tester.pumpAndSettle();
      expect(find.text('维护中'), findsOneWidget);
      expect(find.text('标题p'), findsNothing);
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byTooltip('关闭'), findsNothing);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('维护中'), findsOneWidget);

      clock = DateTime.utc(2026, 1, 1, 0, 2);
      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();
      expect(find.text('维护中'), findsNothing);
      expect(find.text('标题p'), findsOneWidget);
    });
  });
}
