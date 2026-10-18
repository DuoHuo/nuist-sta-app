import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/shell/profile/about/about_page.dart';
import 'package:nuist_sta_app/shell/profile/about/contributor_controller.dart';
import 'package:nuist_sta_app/shell/profile/about/contributor_models.dart';
import 'package:nuist_sta_app/shell/profile/about/contributor_store.dart';

class _FakeStore implements ContributorStore {
  _FakeStore([this.cache]);

  ContributorCache? cache;

  @override
  Future<ContributorCache?> read() async => cache;

  @override
  Future<void> save(ContributorCache c) async => cache = c;
}

void main() {
  final now = DateTime(2025, 1, 2, 12);

  group('解析', () {
    test('正常解析、缺 name 跳过、avatar 缺失或空串为 null', () {
      final list = parseContributorsResponse({
        'code': 0,
        'data': [
          {'name': '张三', 'avatar': 'https://example.com/a.png'},
          {'name': '李四'},
          {'name': '王五', 'avatar': ''},
          {'avatar': 'https://example.com/b.png'},
          {'name': '  '},
          'bad',
        ],
      });
      expect(list.map((c) => c.name), ['张三', '李四', '王五']);
      expect(list[0].avatar, 'https://example.com/a.png');
      expect(list[1].avatar, isNull);
      expect(list[2].avatar, isNull);
    });

    test('code 不为 0 或 data 不是数组时抛错', () {
      expect(
        () => parseContributorsResponse({'code': 1, 'data': []}),
        throwsFormatException,
      );
      expect(
        () => parseContributorsResponse({'code': 0, 'data': {}}),
        throwsFormatException,
      );
      expect(() => parseContributorsResponse(null), throwsFormatException);
    });

    test('缓存序列化往返', () {
      final cache = ContributorCache(
        items: const [Contributor(name: '张三', avatar: 'x')],
        fetchedAt: now,
      );
      final back = ContributorCache.fromJson(cache.toJson())!;
      expect(back.fetchedAt, now);
      expect(back.items.single.name, '张三');
      expect(back.items.single.avatar, 'x');
    });
  });

  group('24h 过期', () {
    test('23h59m 未过期，24h 过期，未来时间过期', () {
      ContributorCache at(DateTime t) =>
          ContributorCache(items: const [], fetchedAt: t);
      expect(
        at(now.subtract(const Duration(hours: 23, minutes: 59))).isStale(now),
        isFalse,
      );
      expect(at(now.subtract(const Duration(hours: 24))).isStale(now), isTrue);
      expect(at(now.add(const Duration(hours: 1))).isStale(now), isTrue);
    });
  });

  group('控制器', () {
    test('有新鲜缓存不请求', () async {
      var calls = 0;
      final c = ContributorController(
        store: _FakeStore(
          ContributorCache(
            items: const [Contributor(name: '缓存')],
            fetchedAt: now.subtract(const Duration(hours: 1)),
          ),
        ),
        fetch: () async {
          calls++;
          return const [];
        },
        now: () => now,
      );
      await c.load();
      expect(calls, 0);
      expect(c.items!.single.name, '缓存');
    });

    test('过期缓存请求失败仍显示缓存', () async {
      final c = ContributorController(
        store: _FakeStore(
          ContributorCache(
            items: const [Contributor(name: '缓存')],
            fetchedAt: now.subtract(const Duration(days: 2)),
          ),
        ),
        fetch: () async => throw Exception('net'),
        now: () => now,
      );
      await c.load();
      expect(c.items!.single.name, '缓存');
      expect(c.failed, isFalse);
      expect(c.loading, isFalse);
    });

    test('过期缓存请求成功则更新并写缓存', () async {
      final store = _FakeStore(
        ContributorCache(
          items: const [Contributor(name: '旧')],
          fetchedAt: now.subtract(const Duration(days: 2)),
        ),
      );
      final c = ContributorController(
        store: store,
        fetch: () async => const [Contributor(name: '新')],
        now: () => now,
      );
      await c.load();
      expect(c.items!.single.name, '新');
      expect(store.cache!.fetchedAt, now);
    });

    test('无缓存失败置 failed，重试成功后恢复', () async {
      var fail = true;
      final c = ContributorController(
        store: _FakeStore(),
        fetch: () async {
          if (fail) throw Exception('net');
          return const [Contributor(name: '张三')];
        },
        now: () => now,
      );
      await c.load();
      expect(c.items, isNull);
      expect(c.failed, isTrue);
      fail = false;
      await c.retry();
      expect(c.failed, isFalse);
      expect(c.items!.single.name, '张三');
    });
  });

  test('版本号格式', () {
    expect(formatAppVersion('1.2.3', '45'), 'v1.2.3 (45)');
    expect(formatAppVersion('1.2.3', ''), 'v1.2.3');
  });
}
