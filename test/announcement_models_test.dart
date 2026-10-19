// 公告模型：容错解析、过滤、排序、版本比较、缓存序列化。
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_models.dart';

Map<String, dynamic> item(String id, [Map<String, dynamic> extra = const {}]) =>
    {'id': id, 'title': '标题$id', ...extra};

void main() {
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

  test('不可关闭但无 expiresAt 视为可关闭', () {
    final a = Announcement.tryParse(item('a', {'dismissible': false}))!;
    expect(a.blocking, isFalse);
    final b = Announcement.tryParse(
      item('b', {'dismissible': false, 'expiresAt': '2030-01-01T00:00:00Z'}),
    )!;
    expect(b.blocking, isTrue);
  });

  test('过期与版本区间过滤', () {
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
    final ids = visibleAnnouncements(
      all,
      now: now,
      appVersion: '1.10.0',
    ).map((a) => a.id).toSet();
    expect(ids, {'ok', 'min', 'eq'});
    final noVer = visibleAnnouncements(all, now: now, appVersion: null);
    expect(noVer.map((a) => a.id).toSet(), {'ok', 'min', 'max', 'eq'});
  });

  test('compareVersions', () {
    expect(compareVersions('1.2', '1.2.0'), 0);
    expect(compareVersions('1.10', '1.9'), greaterThan(0));
    expect(compareVersions('0.1.0+4', '0.1.0'), 0);
    expect(compareVersions('0.0.9', '0.1'), lessThan(0));
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
      appVersion: null,
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
      etag: '"e"',
      lastModified: 'Wed, 01 Jan 2026 00:00:00 GMT',
      fetchedAt: DateTime.utc(2026, 1, 2),
    );
    final back = AnnouncementCache.fromJson(cache.toJson());
    expect(back.toJson(), cache.toJson());
    expect(() => AnnouncementCache.fromJson({'x': 1}), throwsFormatException);
  });
}
