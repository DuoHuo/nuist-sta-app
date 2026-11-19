import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_api.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_detail_page.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_detail_repository.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_detail_store.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_models.dart';

Bulletin _bulletin(int id, {String? url}) => Bulletin(
  id: '$id',
  title: '测试公告 $id',
  url:
      url ?? Uri.parse(bulletinHomeUri).resolve('info/1234/$id.htm').toString(),
  officialCategory: '其他',
  publisher: '测试单位',
  publishedAt: '',
);

const _oldDocument = BulletinDetailDocument(
  blocks: [
    BulletinDetailBlock(
      kind: BulletinDetailBlockKind.paragraph,
      text: '已保存的旧正文',
    ),
    BulletinDetailBlock(
      kind: BulletinDetailBlockKind.table,
      items: ['事项 · 时间', '材料领取 · 上午'],
    ),
    BulletinDetailBlock(
      kind: BulletinDetailBlockKind.image,
      url: 'https://bulletin.campus.invalid/photo.png',
      altText: '说明图',
      centered: true,
    ),
  ],
  attachments: [
    BulletinAttachment(
      name: '申请表.pdf',
      url: 'https://bulletin.campus.invalid/download?id=1',
    ),
  ],
);

BulletinDetailDocument _document(String text) => BulletinDetailDocument(
  blocks: [
    BulletinDetailBlock(kind: BulletinDetailBlockKind.paragraph, text: text),
  ],
  attachments: const [],
);

class _FakeApi extends BulletinApi {
  final requests = <String>[];
  Future<BulletinDetailDocument?> Function(Bulletin)? respond;

  @override
  Future<BulletinDetailDocument?> fetchDetail(Bulletin bulletin) async {
    requests.add(bulletin.id);
    return respond == null
        ? _document('正文 ${bulletin.id}')
        : respond!(bulletin);
  }
}

class _RedirectAdapter implements HttpClientAdapter {
  _RedirectAdapter(this.location);

  final String location;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (requests.length == 1) {
      return ResponseBody.fromString(
        '',
        302,
        headers: {
          HttpHeaders.locationHeader: [location],
        },
      );
    }
    return ResponseBody.fromString(
      '<div class="wp_articlecontent"><p>官网跳转后的正文</p></div>',
      200,
    );
  }

  @override
  void close({bool force = false}) {}
}

Iterable<File> _snapshots(Directory directory) => directory
    .listSync(recursive: true)
    .whereType<File>()
    .where((file) => file.path.endsWith('.json'));

void main() {
  test('正文请求只跟随官网内跳转，不访问跳转目标之外的域名', () async {
    final bulletin = _bulletin(1);
    final dio = Dio();
    addTearDown(() => dio.close(force: true));
    final api = BulletinApi(dio: dio);
    final internal = _RedirectAdapter('/info/1234/2.htm');
    dio.httpClientAdapter = internal;
    final document = await api.fetchDetail(bulletin);
    expect(document?.blocks.single.text, '官网跳转后的正文');
    expect(internal.requests.map((request) => request.uri.path), [
      '/info/1234/1.htm',
      '/info/1234/2.htm',
    ]);
    expect(
      internal.requests.every((request) => !request.followRedirects),
      isTrue,
    );

    final external = _RedirectAdapter('https://bulletin.campus.invalid/other');
    dio.httpClientAdapter = external;
    expect(await api.fetchDetail(bulletin), isNull);
    expect(external.requests, hasLength(1));
  });

  test('重新创建仓库后仍读到本地正文、表格、图片地址和附件链接', () async {
    final directory = await Directory.systemTemp.createTemp('bulletin-reopen-');
    addTearDown(() => directory.delete(recursive: true));
    final uri = Uri.parse(_bulletin(1).url);
    final store = BulletinDetailStore(resolveDirectory: () async => directory);
    await store.save(uri, _oldDocument);

    final api = _FakeApi();
    final reopened = BulletinDetailRepository(
      api: api,
      store: BulletinDetailStore(resolveDirectory: () async => directory),
    );
    final entry = (await reopened.read(_bulletin(1)))!;
    expect(reopened.isFresh(entry), isTrue);
    expect(entry.document.blocks.map((block) => block.kind), [
      BulletinDetailBlockKind.paragraph,
      BulletinDetailBlockKind.table,
      BulletinDetailBlockKind.image,
    ]);
    expect(entry.document.blocks.first.text, '已保存的旧正文');
    expect(entry.document.blocks[1].items.last, '材料领取 · 上午');
    expect(entry.document.blocks.last.centered, isTrue);
    expect(entry.document.blocks.last.altText, '说明图');
    expect(entry.document.blocks.last.url, _oldDocument.blocks.last.url);
    expect(entry.document.attachments.single.name, '申请表.pdf');
    expect(
      entry.document.attachments.single.url,
      _oldDocument.attachments.single.url,
    );
    expect(api.requests, isEmpty);
  });

  test('缓存损坏像未命中，超大正文不替换快照，到期快照不再读', () async {
    final directory = await Directory.systemTemp.createTemp('bulletin-expiry-');
    addTearDown(() => directory.delete(recursive: true));
    var now = DateTime.utc(2026, 11, 14, 12);
    final store = BulletinDetailStore(
      resolveDirectory: () async => directory,
      now: () => now,
    );
    final uri = Uri.parse(_bulletin(1).url);
    await store.save(uri, _oldDocument);
    await store.save(uri, _document('x' * (512 * 1024)));
    expect((await store.read(uri))!.document.blocks.first.text, '已保存的旧正文');
    await _snapshots(directory).single.writeAsString('{');
    expect(await store.read(uri), isNull);
    await store.save(uri, _oldDocument);
    expect(await store.read(uri), isNotNull);
    now = now.add(const Duration(days: 7));
    expect(await store.read(uri), isNull);
  });

  test('缓存超过 24 篇时淘汰最早写入的正文', () async {
    final directory = await Directory.systemTemp.createTemp('bulletin-limit-');
    addTearDown(() => directory.delete(recursive: true));
    var now = DateTime.utc(2026, 11, 14, 12);
    final store = BulletinDetailStore(
      resolveDirectory: () async => directory,
      now: () => now,
    );
    for (var i = 0; i < 25; i++) {
      await store.save(Uri.parse(_bulletin(i).url), _document('正文 $i'));
      now = now.add(const Duration(minutes: 1));
    }
    expect(_snapshots(directory), hasLength(24));
    expect(await store.read(Uri.parse(_bulletin(0).url)), isNull);
    expect(
      (await store.read(Uri.parse(_bulletin(24).url)))!
          .document
          .blocks
          .single
          .text,
      '正文 24',
    );
  });

  test('预加载与主动打开同一篇共用请求，离开后不发下一篇', () async {
    final started = Completer<void>();
    final result = Completer<BulletinDetailDocument>();
    final api = _FakeApi()
      ..respond = (_) {
        started.complete();
        return result.future;
      };
    final repository = BulletinDetailRepository(api: api);
    var active = true;
    final first = _bulletin(1);
    final preload = repository.preload([
      first,
      _bulletin(2),
    ], shouldContinue: () => active);
    await started.future;
    final open = repository.refresh(first);
    active = false;
    result.complete(_oldDocument);

    expect(await open, same(_oldDocument));
    await preload;
    expect(api.requests, ['1']);
    expect((await repository.read(first))!.document, same(_oldDocument));
  });

  test('切换分类时只继续最新一轮，跳过外部地址并限制预读数量', () async {
    final started = Completer<void>();
    final gate = Completer<BulletinDetailDocument>();
    final api = _FakeApi()
      ..respond = (item) async {
        if (item.id != '1') return _document('新分类');
        started.complete();
        return gate.future;
      };
    final repository = BulletinDetailRepository(api: api);
    final old = repository.preload([
      _bulletin(1),
      _bulletin(2),
    ], shouldContinue: () => true);
    await started.future;
    final latest = repository.preload([
      _bulletin(3, url: 'https://bulletin.campus.invalid/other'),
      _bulletin(4),
      _bulletin(5),
      _bulletin(6),
    ], shouldContinue: () => true);
    gate.complete(_oldDocument);
    await Future.wait([old, latest]);
    expect(api.requests, ['1', '4', '5']);
    await repository.preload([
      _bulletin(4),
      _bulletin(5),
    ], shouldContinue: () => true);
    expect(api.requests, ['1', '4', '5']);
  });

  for (final offline in [false, true]) {
    testWidgets('旧正文先显示，再处理网络结果：断网=$offline', (tester) async {
      var now = DateTime.utc(2026, 11, 14, 12);
      final api = _FakeApi()..respond = (_) async => _document('已缓存正文');
      final repository = BulletinDetailRepository(api: api, now: () => now);
      final bulletin = _bulletin(1);
      await repository.refresh(bulletin);
      now = now.add(const Duration(hours: 2));
      final latest = Completer<BulletinDetailDocument>();
      api.respond = (_) => latest.future;
      await tester.pumpWidget(
        MaterialApp(
          home: BulletinDetailPage(bulletin: bulletin, repository: repository),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已缓存正文'), findsOneWidget);
      expect(find.text('当前显示缓存内容'), findsOneWidget);
      expect(find.byTooltip('复制全文'), findsOneWidget);
      expect(api.requests, ['1', '1']);

      if (offline) {
        latest.completeError(const SocketException('模拟断网'));
      } else {
        latest.complete(_document('更新后的正文'));
      }
      await tester.pumpAndSettle();
      expect(find.text('已缓存正文'), offline ? findsOneWidget : findsNothing);
      expect(find.text('更新后的正文'), offline ? findsNothing : findsOneWidget);
      expect(find.text('当前显示缓存内容'), offline ? findsOneWidget : findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('正文扫描图保持比例并按阅读宽度限制解码尺寸', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _FakeApi()
      ..respond = (_) async => const BulletinDetailDocument(
        blocks: [
          BulletinDetailBlock(
            kind: BulletinDetailBlockKind.image,
            url: 'https://bulletin.campus.invalid/scan.jpg',
            altText: '扫描图',
          ),
        ],
        attachments: [],
      );
    final repository = BulletinDetailRepository(api: api);
    final bulletin = _bulletin(1);
    await repository.refresh(bulletin);
    await tester.pumpWidget(
      MaterialApp(
        home: BulletinDetailPage(bulletin: bulletin, repository: repository),
      ),
    );
    await tester.pumpAndSettle();
    final provider =
        tester.widget<Image>(find.byType(Image)).image as ResizeImage;
    expect(provider.width, 1074);
    expect(provider.height, 4096);
    expect(provider.policy, ResizeImagePolicy.fit);
    expect(provider.allowUpscaling, isFalse);
    expect(find.text('扫描图'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('新鲜缓存打开时不请求，手动刷新仍可读到新版', (tester) async {
    final api = _FakeApi()..respond = (_) async => _document('已缓存正文');
    final repository = BulletinDetailRepository(api: api);
    final bulletin = _bulletin(1);
    await repository.refresh(bulletin);
    await tester.pumpWidget(
      MaterialApp(
        home: BulletinDetailPage(bulletin: bulletin, repository: repository),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已缓存正文'), findsOneWidget);
    expect(api.requests, ['1']);

    api.respond = (_) async => _document('手动取得的正文');
    await tester.tap(find.byTooltip('刷新正文'));
    await tester.pumpAndSettle();
    expect(find.text('手动取得的正文'), findsOneWidget);
    expect(api.requests, ['1', '1']);
  });
}
