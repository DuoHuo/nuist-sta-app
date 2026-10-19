// 公告 controller：条件请求、304、失败回退、红点、已读、不可关闭保护。
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_api.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_controller.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_models.dart';

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
  }) : readIds = readIds ?? <String>{},
       respond =
           respond ?? (() => const AnnouncementFetchResult(notModified: true));

  AnnouncementCache? cache;
  Set<String> readIds;
  AnnouncementFetchResult Function() respond;
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
  );
}

AnnouncementCache cacheOf(List<Announcement> items) => AnnouncementCache(
  items: items,
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

  test('已读集清理列表中已不存在的 id', () async {
    final h = Harness(
      readIds: {'1', 'gone'},
      respond: () =>
          AnnouncementFetchResult(notModified: false, items: [a('1')]),
    );
    await h.controller.ensureStarted();
    expect(h.readIds, {'1'});
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
