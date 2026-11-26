import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'dart:async';

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/app_directories.dart';
import 'package:nuist_sta_app/core/config/campus_config.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_api.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_attachment_preview.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_controller.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_detail_parser.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_detail_repository.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_detail_store.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_home_card.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_models.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_store.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_tagger.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('默认无状态Dio按标准拦截器跟随官网重定向并保留最终地址', () async {
    final adapter = _RedirectBulletinAdapter((options) {
      expect(
        options.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('cookie')),
      );
      if (options.uri.path.endsWith('/first.htm')) {
        return ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': ['/info/1001/final.htm'],
          },
        );
      }
      return ResponseBody.fromString(
        '<div class="wp_articlecontent"><p>合成公告正文。</p></div>',
        200,
      );
    });
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(() => dio.close(force: true));
    final result = await BulletinApi(dio: dio).fetchDetail(
      Bulletin(
        id: 'test',
        title: '测试公告',
        officialCategory: '测试',
        publisher: '测试单位',
        publishedAt: '2026-11-22',
        url: 'https://${CampusHosts.bulletin}/info/1001/first.htm',
      ),
    );
    expect(result, isNotNull);
    expect(adapter.requests.map((options) => options.uri.path), [
      '/info/1001/first.htm',
      '/info/1001/final.htm',
    ]);
  });

  test('公告跳转离开官网允许原点时返回网页入口', () async {
    for (final target in [
      'https://outside.example.test/article',
      'http://${CampusHosts.bulletin}/article',
      'https://${CampusHosts.bulletin}:8443/article',
    ]) {
      final adapter = _RedirectBulletinAdapter(
        (options) => ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': [target],
          },
        ),
      );
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(() => dio.close(force: true));
      expect(
        await BulletinApi(dio: dio).fetchDetail(
          Bulletin(
            id: 'test',
            title: '测试公告',
            officialCategory: '测试',
            publisher: '测试单位',
            publishedAt: '2026-11-22',
            url: 'https://${CampusHosts.bulletin}/info/1001/first.htm',
          ),
        ),
        isNull,
        reason: target,
      );
      expect(adapter.requests, hasLength(1), reason: target);
    }
  });

  test('公告按标题和官网分类生成主题与行为标签', () {
    final bulletin = tagBulletin(
      const Bulletin(
        id: '12345',
        title: '关于开展数学建模竞赛报名的通知',
        url: 'https://bulletin.campus.invalid/info/1/12345.htm',
        officialCategory: '创新创业',
        publisher: '教务处',
        publishedAt: '2026-09-27',
      ),
    );

    expect(
      bulletin.topics,
      containsAll([
        BulletinTopic.academicCompetition,
        BulletinTopic.innovationEntrepreneurship,
      ]),
    );
    expect(bulletin.actions, contains('报名'));
  });

  test('接口后台解析列表、分类、分页、长正文、附件和网页兜底', () async {
    final uri = Uri.parse('https://bulletin.campus.invalid/');
    const listHtml = '''
      <ul>
        <li class="news">
          <a title="专题学术报告通知" href="/info/1001/12345.htm">专题学术报告通知</a>
          <span class="wjj">[学术报告]</span>
          <span class="news_org">科研处</span>
          <span class="news_date">2026-09-27</span>
        </li>
      </ul>
      <div class="wp_paging">总共 100 条 <a href="index_2.htm">下页</a></div>
    ''';
    final dio = Dio()..httpClientAdapter = _BulletinAdapter(listHtml);
    addTearDown(() => dio.close(force: true));
    final api = BulletinApi(dio: dio);
    final page = await api.fetchPage(uri, pageNumber: 1);
    expect(
      page.toJson(),
      parseBulletinPage(listHtml, currentUri: uri, pageNumber: 1).toJson(),
    );
    expect(page.items, hasLength(1));
    expect(page.items.single.id, '12345');
    expect(page.items.single.officialCategory, '学术报告');
    expect(page.items.single.publisher, '科研处');
    expect(page.items.single.topics, contains(BulletinTopic.academicTalks));
    expect(page.totalCount, 100);
    expect(page.nextUrl, 'https://bulletin.campus.invalid/index_2.htm');

    dio.httpClientAdapter = _BulletinAdapter(
      '<div class="wp_articlecontent">'
      '${List.generate(1000, (i) => '<p>合成段落 $i</p>').join()}'
      '<a href="/files/test.pdf">测试附件.pdf</a></div>',
    );
    final document = await api.fetchDetail(page.items.single);
    expect(document!.blocks.first.text, '合成段落 0');
    expect(document.blocks.map((b) => b.text), contains('合成段落 999'));
    expect(document.attachments.single.name, '测试附件.pdf');
    expect(document.attachments.single.url, '${uri}files/test.pdf');

    dio.httpClientAdapter = _BulletinAdapter('该信息仅允许校内地址访问');
    expect(await api.fetchDetail(page.items.single), isNull);
  });

  test('公告缓存后台编解码保留全部字段，连续保存按调用顺序完成', () async {
    final directory = await Directory.systemTemp.createTemp('bulletin-cache-');
    addTearDown(() => directory.delete(recursive: true));
    final store = BulletinStore(resolveDirectory: () async => directory);
    final items = List.generate(
      200,
      (i) => Bulletin(
        id: 'synthetic-$i',
        title: '合成公告 $i',
        url: 'https://bulletin.campus.invalid/info/1/$i.htm',
        officialCategory: '学术报告',
        publisher: '测试单位',
        publishedAt: '2026-09-27',
      ),
    );
    final data = BulletinLocalData(
      subscription: const BulletinSubscription(
        enabled: true,
        topics: {BulletinTopic.academicTalks},
      ),
      pages: {'all|1': BulletinListPage(items: items, pageNumber: 1)},
      feed: items.take(3).toList(),
    );
    await store.save(data);
    expect((await store.read()).toJson(), data.toJson());

    final first = store.save(data);
    const latest = BulletinLocalData();
    final second = store.save(latest);
    expect((await store.read()).toJson(), latest.toJson());
    await Future.wait([first, second]);

    final file = File(
      '${directory.path}${Platform.pathSeparator}announcements'
      '${Platform.pathSeparator}announcements.json',
    );
    await file.writeAsString(
      jsonEncode({
        ...data.toJson(),
        'knownIds': ['old'],
        'baselineReady': true,
      }),
    );
    expect((await store.read()).toJson(), data.toJson());
    await file.writeAsString('{');
    expect((await store.read()).toJson(), const BulletinLocalData().toJson());
    await store.save(data);
    expect((await store.read()).toJson(), data.toJson());
  });

  group('公告附件下载文件名', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('bulletin-test-');
      AppDirectories.overrideForTesting(temporary: () async => directory);
    });

    tearDown(() async {
      AppDirectories.resetForTesting();
      await directory.delete(recursive: true);
    });

    for (final sample in [
      (
        name: '申请表.pdf',
        path: '/system/_content/download.jsp?urltype=news.DownloadAttachUrl&wbfileid=11',
        expected: '申请表.pdf',
      ),
      (name: '申请表', path: '/files/form.pdf', expected: '申请表.pdf'),
    ]) {
      test('保存 ${sample.path} 时使用 ${sample.expected}', () async {
        const payload = 'synthetic attachment bytes';
        final dio = Dio()..httpClientAdapter = _BulletinAdapter(payload);
        addTearDown(() => dio.close(force: true));
        final file = await BulletinApi(dio: dio).downloadAttachment(
          BulletinAttachment(
            name: sample.name,
            url: 'https://bulletin.campus.invalid${sample.path}',
          ),
        );

        expect(
          file.uri.pathSegments.last,
          'nuist-announcement-${sample.expected}',
        );
        expect(await file.readAsString(), payload);
      });
    }

    test('官网下载响应可恢复带中文和实际扩展名的附件名', () async {
      final dio = Dio()
        ..httpClientAdapter = _BulletinAdapter(
          'synthetic attachment bytes',
          headers: {
            'content-disposition': [
              "attachment; filename=old.dat; filename*=UTF-8''..%2F%E6%8A%A5%E5%90%8D%E8%A1%A8.docx",
            ],
          },
        );
      addTearDown(() => dio.close(force: true));
      final file = await BulletinApi(dio: dio).downloadAttachment(
        const BulletinAttachment(
          name: '附件',
          url: 'https://bulletin.campus.invalid/system/download.jsp?id=1',
        ),
      );
      expect(file.uri.pathSegments.last, 'nuist-announcement-报名表.docx');
      expect(await file.readAsString(), 'synthetic attachment bytes');
    });
  });

  test('BulletinController 按分类缓存列表并在翻页、强刷和切分类时准确失效', () async {
    const b1 = Bulletin(
      id: '1',
      title: '公告 1',
      url: 'https://bulletin.campus.invalid/info/1/1.htm',
      officialCategory: '教学考试',
      publisher: '教务处',
      publishedAt: '2026-10-01',
    );
    const b2 = Bulletin(
      id: '2',
      title: '公告 2',
      url: 'https://bulletin.campus.invalid/info/1/2.htm',
      officialCategory: '教学考试',
      publisher: '教务处',
      publishedAt: '2026-10-02',
    );
    const b3 = Bulletin(
      id: '3',
      title: '公告 3',
      url: 'https://bulletin.campus.invalid/info/1/3.htm',
      officialCategory: '科研信息',
      publisher: '科研处',
      publishedAt: '2026-10-03',
    );
    const b4 = Bulletin(
      id: '4',
      title: '文件公告 1',
      url: 'https://bulletin.campus.invalid/info/1/4.htm',
      officialCategory: '文件公告',
      publisher: '党政办',
      publishedAt: '2026-10-04',
    );
    const b4Updated = Bulletin(
      id: '4-new',
      title: '文件公告更新',
      url: 'https://bulletin.campus.invalid/info/1/4-new.htm',
      officialCategory: '文件公告',
      publisher: '党政办',
      publishedAt: '2026-10-05',
    );

    final allCategory = BulletinCategory.all.first;
    final docCategory = BulletinCategory.all[1];
    final nextPageUrl = 'https://bulletin.campus.invalid/index_2.htm';

    final pages = <String, BulletinListPage>{
      allCategory.uri.toString(): BulletinListPage(
        items: const [b1, b2],
        pageNumber: 1,
        nextUrl: nextPageUrl,
      ),
      nextPageUrl: const BulletinListPage(
        // 包含重复 id=2，验证翻页合并时去重与顺序保持。
        items: [b2, b3],
        pageNumber: 2,
      ),
      docCategory.uri.toString(): const BulletinListPage(
        items: [b4],
        pageNumber: 1,
      ),
    };
    final api = _PagedFixtureApi(pages);
    final controller = BulletinController(api: api, store: _MemoryStore());
    addTearDown(controller.dispose);

    await controller.loadCategory(allCategory);
    final firstRead = controller.items;
    final secondRead = controller.items;
    expect(identical(firstRead, secondRead), isTrue);
    expect(firstRead.map((b) => b.id), ['1', '2']);

    await controller.loadMore();
    final afterLoadMore = controller.items;
    expect(identical(afterLoadMore, firstRead), isFalse);
    expect(identical(controller.items, afterLoadMore), isTrue);
    expect(afterLoadMore.map((b) => b.id), ['1', '2', '3']);

    await controller.selectCategory(docCategory);
    final docFirstRead = controller.items;
    expect(docFirstRead.map((b) => b.id), ['4']);
    expect(identical(controller.items, docFirstRead), isTrue);

    // 切回全部分类直接命中已缓存列表。
    await controller.selectCategory(allCategory);
    expect(identical(controller.items, afterLoadMore), isTrue);

    // 强刷文件公告后缓存失效并返回新数据。
    pages[docCategory.uri.toString()] = const BulletinListPage(
      items: [b4Updated],
      pageNumber: 1,
    );
    await controller.selectCategory(docCategory);
    await controller.loadCategory(docCategory, forceRefresh: true);
    expect(identical(controller.items, docFirstRead), isFalse);
    expect(controller.items.map((b) => b.id), ['4-new']);
  });

  group('附件预览与缓存清理', () {
    const pdfChannel = MethodChannel('dev.duohuo.nuist_sta_app/attachment_pdf');
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMwnvn/PwAFmQLLFOU//QAAAABJRU5ErkJggg==',
    );
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('bulletin-s8-test-');
    });

    tearDown(() async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(pdfChannel, null);
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('BulletinPdfDocument 兼容可选 probedPageCount 并按需传 targetWidth', () async {
      final pdfFile = File('${tempDir.path}/sample.pdf')
        ..writeAsBytesSync(ascii.encode('%PDF-1.4'));
      final renderCalls = <Map<Object?, Object?>>[];
      int? responseProbedCount = 2;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(pdfChannel, (
        call,
      ) async {
        return switch (call.method) {
          'open' => {
            'id': 9,
            'pageAspectRatios': [0.7, 0.8, 0.7, 0.7],
            'probedPageCount': ?responseProbedCount,
          },
          'render' => () {
            renderCalls.add(call.arguments as Map<Object?, Object?>);
            return png;
          }(),
          _ => null,
        };
      });

      final doc = await BulletinPdfDocument.open(pdfFile);
      expect(doc.probedPageCount, 2);
      await doc.renderPage(0);
      await doc.renderPage(1, targetWidth: 1080);
      await doc.close();

      expect(renderCalls, hasLength(2));
      expect(renderCalls[0].containsKey('width'), isFalse);
      expect(renderCalls[1]['width'], 1080);

      responseProbedCount = null;
      final legacy = await BulletinPdfDocument.open(pdfFile);
      expect(legacy.probedPageCount, 4);
      await legacy.close();
    });

    test('BulletinApi.trimAttachmentCache 清理超期与超容量目录并保留 preserve', () async {
      final now = DateTime.utc(2026, 11, 23, 12);

      Future<Directory> createAttachmentDir(
        String name, {
        required int sizeBytes,
        required DateTime modified,
      }) async {
        final dir = Directory('${tempDir.path}${Platform.pathSeparator}$name');
        await dir.create(recursive: true);
        final file = File('${dir.path}/payload.bin');
        await file.writeAsBytes(List<int>.filled(sizeBytes, 1));
        await file.setLastModified(modified);
        return dir;
      }

      final expiredDir = await createAttachmentDir(
        'attachment-expired',
        sizeBytes: 32,
        modified: now.subtract(const Duration(days: 8)),
      );
      final oldDir = await createAttachmentDir(
        'attachment-old',
        sizeBytes: 60,
        modified: now.subtract(const Duration(days: 3)),
      );
      final recentDir = await createAttachmentDir(
        'attachment-recent',
        sizeBytes: 60,
        modified: now.subtract(const Duration(days: 1)),
      );
      final preservedDir = await createAttachmentDir(
        'attachment-preserve',
        sizeBytes: 50,
        modified: now.subtract(const Duration(days: 10)),
      );

      // 预算 120 字节：preserve 占 50 字节（即使超过 7 天也绝不删除），
      // recentDir (60 字节) 可保留（50 + 60 <= 120），
      // oldDir (60 字节) 超出预算被清理，expiredDir 超期被清理。
      // 用带有「.」的路径指向同一目录，覆盖各平台上的路径别名。
      await BulletinApi.trimAttachmentCache(
        tempDir,
        preserve: Directory('${tempDir.path}/./attachment-preserve'),
        maxAge: const Duration(days: 7),
        maxBytes: 120,
        now: now,
      );

      expect(await preservedDir.exists(), isTrue);
      expect(await recentDir.exists(), isTrue);
      expect(await oldDir.exists(), isFalse);
      expect(await expiredDir.exists(), isFalse);
    });
  });

  group('BulletinController 订阅刷新、重试与冷却', () {
    const subscription = BulletinSubscription(
      enabled: true,
      topics: {BulletinTopic.courses},
    );
    const oldItem = Bulletin(
      id: 'old',
      title: '已缓存的选课通知',
      url: 'https://bulletin.campus.invalid/info/1/old.htm',
      officialCategory: '教学考试',
      publisher: '测试单位',
      publishedAt: '2026-10-18',
      topicScores: {'courses': 4},
    );
    const newItem = Bulletin(
      id: 'new',
      title: '新的选课通知',
      url: 'https://bulletin.campus.invalid/info/1/new.htm',
      officialCategory: '教学考试',
      publisher: '测试单位',
      publishedAt: '2026-10-19',
      topicScores: {'courses': 4},
    );
    const historical = Bulletin(
      id: 'historical',
      title: '往年的选课说明',
      url: 'https://bulletin.campus.invalid/info/1/historical.htm',
      officialCategory: '教学考试',
      publisher: '测试单位',
      publishedAt: '2016-02-01',
      topicScores: {'courses': 4},
    );
    const unmatched = Bulletin(
      id: 'unmatched',
      title: '讲座通知',
      url: 'https://bulletin.campus.invalid/info/1/unmatched.htm',
      officialCategory: '学术报告',
      publisher: '测试单位',
      publishedAt: '2026-10-20',
      topicScores: {'academicTalks': 4},
    );

    test('按发布时间和主题选最近两条，跨页补入且旧置顶不挤掉较新公告', () {
      fakeAsync((async) {
        final index = BulletinCategory.all.first.uri;
        final pages = <String, BulletinListPage>{
          index.toString(): BulletinListPage(
            items: const [historical, newItem, unmatched],
            pageNumber: 1,
            nextUrl: index.resolve('index_2.htm').toString(),
          ),
          index.resolve('index_2.htm').toString(): const BulletinListPage(
            items: [oldItem],
            pageNumber: 2,
          ),
        };
        final controller = BulletinController(
          api: _PagedFixtureApi(pages),
          store: _MemoryStore()
            ..data = const BulletinLocalData(subscription: subscription),
        );
        addTearDown(controller.dispose);
        controller.ensureStarted();
        async.flushMicrotasks();
        expect(controller.feed, [newItem, oldItem]);
      });
    });

    test('刷新按 2 秒和 4 秒重试，15 分钟冷却与恢复，关闭订阅停止且重开丢弃旧请求', () {
      fakeAsync((async) {
        var now = DateTime(2026, 11, 17, 12);
        var requests = 0;
        var failuresRemaining = 2;
        Completer<BulletinListPage>? pending;
        final api = _RetryFixtureApi(() {
          requests++;
          if (pending != null) return pending.future;
          if (failuresRemaining > 0) {
            failuresRemaining--;
            return Future.error(TimeoutException('合成超时'));
          }
          return Future.value(
            const BulletinListPage(items: [newItem, oldItem], pageNumber: 1),
          );
        });
        final controller = BulletinController(
          api: api,
          now: () => now,
          store: _MemoryStore()
            ..data = const BulletinLocalData(subscription: subscription),
        );
        addTearDown(controller.dispose);
        controller.ensureStarted();
        async.flushMicrotasks();
        expect(requests, 1);
        expect(controller.feedLoading, isTrue);

        // 重试 2s + 4s 成功恢复。
        async.elapse(const Duration(seconds: 2));
        expect(requests, 2);
        async.elapse(const Duration(seconds: 4));
        expect(requests, 3);
        expect(controller.feedUnavailable, isFalse);
        expect(controller.feed, [newItem, oldItem]);

        // 冷却期自动刷新跳过，15 分钟后恢复；手动绕过冷却。
        failuresRemaining = 3;
        controller.refreshFeed();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 6));
        expect(requests, 6);
        controller.refreshFeed(automatic: true);
        expect(requests, 6);
        now = now.add(const Duration(minutes: 15));
        controller.refreshFeed(automatic: true);
        async.flushMicrotasks();
        expect(requests, 7);

        // 关闭订阅停止剩余重试，重开丢弃旧请求。
        final stale = Completer<BulletinListPage>();
        pending = stale;
        controller.refreshFeed();
        async.flushMicrotasks();
        controller.configureSubscription(enabled: false, topics: {});
        pending = null;
        controller.configureSubscription(
          enabled: true,
          topics: subscription.topics,
        );
        stale.complete(const BulletinListPage(items: [oldItem], pageNumber: 1));
        async.flushMicrotasks();
        expect(controller.feed, [newItem, oldItem]);
      });
    });
  });

  group('BulletinDetailParser', () {
    final detailUri = Uri.parse(
      'https://bulletin.campus.invalid/info/1/123.htm',
    );

    test('解析正常正文块与附件，无正文或受限页面返回 null 兜底网页', () {
      final document = parseBulletinDetail('''
      <html><body>
        <div class="wp_articlecontent">
          <h2>Activity plan</h2>
          <p style="text-align:center">Announcement body.</p>
          <ul><li>First item</li><li>Second item</li></ul>
          <p><a href="../../files/notice.pdf">Attachment: notice.pdf</a></p>
        </div>
      </body></html>
      ''', currentUri: detailUri);

      expect(document, isNotNull);
      expect(
        document!.blocks.map((block) => block.kind),
        containsAll([
          BulletinDetailBlockKind.heading,
          BulletinDetailBlockKind.paragraph,
          BulletinDetailBlockKind.bulletList,
        ]),
      );
      expect(document.blocks.first.text, 'Activity plan');
      expect(document.attachments.single.name, 'Attachment: notice.pdf');
      expect(
        document.attachments.single.url,
        'https://bulletin.campus.invalid/files/notice.pdf',
      );

      expect(
        parseBulletinDetail('ONLY_ON_CAMPUS_ADDRESS', currentUri: detailUri),
        isNull,
      );
      expect(
        parseBulletinDetail(
          '<html><body><nav>Home</nav><footer>School</footer></body></html>',
          currentUri: detailUri,
        ),
        isNull,
      );
    });

    test('提取正文外官网附件区、无后缀下载接口与链接文件名，正文内外同附件去重', () {
      final outside = parseBulletinDetail('''
      <div class="article">
        <h1>测试公告</h1>
        <div class="entry"><div class="read">
          <div id="vsb_content_2" class="wp_articlecontent">
            <p>请查阅下方材料。</p>
          </div>
          <div id="div_vote_id"></div>
          <p><ul style="list-style-type:none;">
            <li>附件【<a href="/system/_content/download.jsp?urltype=news.DownloadAttachUrl&amp;owner=1&amp;wbfileid=11">材料.pdf</a>】已下载<span>3</span>次</li>
            <li>附件【<a href="/system/_content/download.jsp?urltype=news.DownloadAttachUrl&amp;owner=1&amp;wbfileid=12">申请表.xlsx</a>】已下载<span>2</span>次</li>
          </ul></p>
        </div></div>
      </div>
      ''', currentUri: detailUri)!;
      expect(outside.attachments.map((item) => item.name), [
        '材料.pdf',
        '申请表.xlsx',
      ]);
      expect(
        outside.attachments.first.url,
        'https://bulletin.campus.invalid/system/_content/download.jsp?urltype=news.DownloadAttachUrl&owner=1&wbfileid=11',
      );
      expect(outside.blocks.map((block) => block.text), ['请查阅下方材料。']);

      final noExtApi = parseBulletinDetail('''
      <article>
        <div class="wp_articlecontent">
          <p>请查阅材料。</p>
          <p><a href="/files/get?id=11">申请表.DOCX</a></p>
        </div>
        <a href="/system/_content/download.jsp?urltype=news.DownloadAttachUrl&amp;wbfileid=11">申报材料</a>
      </article>
      ''', currentUri: detailUri)!;
      expect(noExtApi.attachments.map((a) => a.name), ['申请表.DOCX', '申报材料']);
      expect(noExtApi.blocks.map((block) => block.text), ['请查阅材料。']);

      final dedup = parseBulletinDetail('''
      <form name="_newscontent_fromname">
        <div class="wp_articlecontent">
          <p>请提交材料。</p>
          <p><a href="../../files/form.docx">申请表.docx</a></p>
        </div>
        <ul><li><a href="/files/form.docx">申请表.docx</a></li></ul>
      </form>
      ''', currentUri: detailUri)!;
      expect(dedup.attachments, hasLength(1));
      expect(dedup.attachments.single.name, '申请表.docx');
      expect(dedup.blocks.map((block) => block.text), ['请提交材料。']);
    });

    test('隔离文章外导航/侧栏/页脚与隐藏区域中的文件链接', () {
      final wrapped = parseBulletinDetail('''
      <header><a href="/files/help.pdf">帮助.pdf</a></header>
      <div class="article">
        <div class="wp_articlecontent"><p>公告正文。</p></div>
        <a href="/files/form.pdf">申请表.pdf</a>
        <aside><a href="/files/related.pdf">相关材料.pdf</a></aside>
      </div>
      <div class="sidebar"><a href="/files/other.pdf">其他公告附件.pdf</a></div>
      <footer><a href="/files/manual.pdf">手册.pdf</a></footer>
      ''', currentUri: detailUri)!;
      expect(wrapped.attachments.single.name, '申请表.pdf');

      final bare = parseBulletinDetail('''
      <body>
        <nav><a href="/help.pdf">帮助.pdf</a></nav>
        <div class="wp_articlecontent"><p>公告正文。</p></div>
        <ul><li><a href="/files/form.pdf">申请表.pdf</a></li></ul>
        <div style="display:none"><a href="/files/hidden.pdf">隐藏.pdf</a></div>
        <footer><a href="/manual.pdf">手册.pdf</a></footer>
      </body>
      ''', currentUri: detailUri)!;
      expect(bare.attachments.single.name, '申请表.pdf');
    });
  });

  group('BulletinDetailCache', () {
    Bulletin detailBulletin(int id, {String? url}) => Bulletin(
      id: '$id',
      title: '测试公告 $id',
      url:
          url ??
          Uri.parse(bulletinHomeUri).resolve('info/1234/$id.htm').toString(),
      officialCategory: '其他',
      publisher: '测试单位',
      publishedAt: '',
    );

    const oldDocument = BulletinDetailDocument(
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

    BulletinDetailDocument doc(String text) => BulletinDetailDocument(
      blocks: [
        BulletinDetailBlock(
          kind: BulletinDetailBlockKind.paragraph,
          text: text,
        ),
      ],
      attachments: const [],
    );

    Iterable<File> snapshots(Directory directory) => directory
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.json'));

    test('重新创建仓库后仍读到本地正文、表格、图片地址和附件链接', () async {
      final directory = await Directory.systemTemp.createTemp(
        'bulletin-reopen-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final uri = Uri.parse(detailBulletin(1).url);
      final store = BulletinDetailStore(
        resolveDirectory: () async => directory,
      );
      await store.save(uri, oldDocument);

      final api = _DetailFakeApi();
      final reopened = BulletinDetailRepository(
        api: api,
        store: BulletinDetailStore(resolveDirectory: () async => directory),
      );
      final entry = (await reopened.read(detailBulletin(1)))!;
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
      expect(entry.document.blocks.last.url, oldDocument.blocks.last.url);
      expect(entry.document.attachments.single.name, '申请表.pdf');
      expect(
        entry.document.attachments.single.url,
        oldDocument.attachments.single.url,
      );
      expect(api.requests, isEmpty);
    });

    test('缓存损坏像未命中，超大正文不替换快照，到期快照不再读', () async {
      final directory = await Directory.systemTemp.createTemp(
        'bulletin-expiry-',
      );
      addTearDown(() => directory.delete(recursive: true));
      var now = DateTime.utc(2026, 11, 14, 12);
      final store = BulletinDetailStore(
        resolveDirectory: () async => directory,
        now: () => now,
      );
      final uri = Uri.parse(detailBulletin(1).url);
      await store.save(uri, oldDocument);
      await store.save(uri, doc('x' * (512 * 1024)));
      expect((await store.read(uri))!.document.blocks.first.text, '已保存的旧正文');
      await snapshots(directory).single.writeAsString('{');
      expect(await store.read(uri), isNull);
      await store.save(uri, oldDocument);
      expect(await store.read(uri), isNotNull);
      now = now.add(const Duration(days: 7));
      expect(await store.read(uri), isNull);
    });

    test('缓存超过 24 篇时淘汰最早写入的正文', () async {
      final directory = await Directory.systemTemp.createTemp(
        'bulletin-limit-',
      );
      addTearDown(() => directory.delete(recursive: true));
      var now = DateTime.utc(2026, 11, 14, 12);
      final store = BulletinDetailStore(
        resolveDirectory: () async => directory,
        now: () => now,
      );
      for (var i = 0; i < 25; i++) {
        await store.save(Uri.parse(detailBulletin(i).url), doc('正文 $i'));
        now = now.add(const Duration(minutes: 1));
      }
      expect(snapshots(directory), hasLength(24));
      expect(await store.read(Uri.parse(detailBulletin(0).url)), isNull);
      expect(
        (await store.read(Uri.parse(detailBulletin(24).url)))!
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
      final api = _DetailFakeApi()
        ..respond = (_) {
          started.complete();
          return result.future;
        };
      final repository = BulletinDetailRepository(api: api);
      var active = true;
      final first = detailBulletin(1);
      final preload = repository.preload([
        first,
        detailBulletin(2),
      ], shouldContinue: () => active);
      await started.future;
      final open = repository.refresh(first);
      active = false;
      result.complete(oldDocument);

      expect(await open, same(oldDocument));
      await preload;
      expect(api.requests, ['1']);
      expect((await repository.read(first))!.document, same(oldDocument));
    });

    test('切换分类时只继续最新一轮，跳过外部地址并限制预读数量', () async {
      final started = Completer<void>();
      final gate = Completer<BulletinDetailDocument>();
      final api = _DetailFakeApi()
        ..respond = (item) async {
          if (item.id != '1') return doc('新分类');
          started.complete();
          return gate.future;
        };
      final repository = BulletinDetailRepository(api: api);
      final old = repository.preload([
        detailBulletin(1),
        detailBulletin(2),
      ], shouldContinue: () => true);
      await started.future;
      final latest = repository.preload([
        detailBulletin(3, url: 'https://bulletin.campus.invalid/other'),
        detailBulletin(4),
        detailBulletin(5),
        detailBulletin(6),
      ], shouldContinue: () => true);
      gate.complete(oldDocument);
      await Future.wait([old, latest]);
      expect(api.requests, ['1', '4', '5']);
      await repository.preload([
        detailBulletin(4),
        detailBulletin(5),
      ], shouldContinue: () => true);
      expect(api.requests, ['1', '4', '5']);
    });
  });

  group('BulletinHomeCard', () {
    testWidgets('未订阅提示、订阅匹配与切换主题刷新、持续失败隐藏异常状态', (tester) async {
      const subscription = BulletinSubscription(
        enabled: true,
        topics: {BulletinTopic.courses},
      );
      const oldBulletin = Bulletin(
        id: 'old',
        title: '已缓存的选课通知',
        url: 'https://bulletin.campus.invalid/info/1/old.htm',
        officialCategory: '教学考试',
        publisher: '测试单位',
        publishedAt: '2026-10-18',
        topicScores: {'courses': 4},
      );
      const newBulletin = Bulletin(
        id: 'new',
        title: '新的选课通知',
        url: 'https://bulletin.campus.invalid/info/1/new.htm',
        officialCategory: '教学考试',
        publisher: '测试单位',
        publishedAt: '2026-10-19',
        topicScores: {'courses': 4},
      );
      const unmatched = Bulletin(
        id: 'unmatched',
        title: '讲座通知',
        url: 'https://bulletin.campus.invalid/info/1/unmatched.htm',
        officialCategory: '学术报告',
        publisher: '测试单位',
        publishedAt: '2026-10-20',
        topicScores: {'academicTalks': 4},
      );
      const page = BulletinListPage(
        items: [newBulletin, oldBulletin, unmatched],
        pageNumber: 1,
      );

      Widget home(BulletinController controller) => MaterialApp(
        theme: appDarkTheme(),
        home: Scaffold(
          body: ListView(children: [BulletinHomeCard(controller: controller)]),
        ),
      );

      final unsubApi = _HomeCardFakeApi(page);
      final unsubController = BulletinController(
        api: unsubApi,
        store: _MemoryStore(),
      );
      addTearDown(unsubController.dispose);
      await tester.pumpWidget(home(unsubController));
      expect(find.text('开启主题订阅，在这里查看最近匹配的公告'), findsOneWidget);
      expect(unsubApi.requests, 0);
      await tester.pumpWidget(const SizedBox.shrink());

      final subApi = _HomeCardFakeApi(page);
      final subController = BulletinController(
        api: subApi,
        store: _MemoryStore(),
      );
      addTearDown(subController.dispose);
      await subController.ensureStarted();
      await subController.configureSubscription(
        enabled: true,
        topics: subscription.topics,
      );
      await tester.pumpWidget(home(subController));
      await tester.pumpAndSettle();
      expect(find.text(newBulletin.title), findsOneWidget);
      expect(find.text(oldBulletin.title), findsOneWidget);
      expect(find.text('2 条动态'), findsOneWidget);
      await subController.configureSubscription(
        enabled: true,
        topics: {BulletinTopic.academicTalks},
      );
      await tester.pump();
      expect(find.text(unmatched.title), findsOneWidget);
      expect(find.text(newBulletin.title), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());

      final failApi = _HomeCardFakeApi(page)..failuresRemaining = 3;
      final failController = BulletinController(
        api: failApi,
        store: _MemoryStore()
          ..data = const BulletinLocalData(
            subscription: subscription,
            feed: [oldBulletin],
          ),
      );
      addTearDown(failController.dispose);
      await tester.pumpWidget(home(failController));
      await tester.pump(const Duration(seconds: 6));

      expect(failController.feedUnavailable, isTrue);
      expect(find.text('信息公告'), findsOneWidget);
      expect(find.text(oldBulletin.title), findsNothing);
      expect(find.textContaining('失败'), findsNothing);
      expect(find.textContaining('DioException'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}

class _BulletinAdapter implements HttpClientAdapter {
  _BulletinAdapter(this.body, {this.headers = const {}});

  final String body;
  final Map<String, List<String>> headers;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(body, 200, headers: headers);

  @override
  void close({bool force = false}) {}
}

class _PagedFixtureApi extends BulletinApi {
  _PagedFixtureApi(this.pages);

  final Map<String, BulletinListPage> pages;

  @override
  Future<BulletinListPage> fetchPage(Uri uri, {required int pageNumber}) async {
    final page = pages[uri.toString()];
    if (page == null) {
      throw StateError('Unexpected bulletin page request: $uri');
    }
    return page;
  }
}

class _MemoryStore extends BulletinStore {
  BulletinLocalData data = const BulletinLocalData();

  @override
  Future<BulletinLocalData> read() async => data;

  @override
  Future<void> save(BulletinLocalData data) async => this.data = data;
}

class _RedirectBulletinAdapter implements HttpClientAdapter {
  _RedirectBulletinAdapter(this.respond);
  final ResponseBody Function(RequestOptions) respond;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

class _RetryFixtureApi extends BulletinApi {
  _RetryFixtureApi(this._fetch);
  final Future<BulletinListPage> Function() _fetch;

  @override
  Future<BulletinListPage> fetchPage(Uri uri, {required int pageNumber}) =>
      _fetch();
}

class _DetailFakeApi extends BulletinApi {
  final requests = <String>[];
  Future<BulletinDetailDocument?> Function(Bulletin)? respond;

  @override
  Future<BulletinDetailDocument?> fetchDetail(Bulletin bulletin) async {
    requests.add(bulletin.id);
    return respond == null ? null : respond!(bulletin);
  }
}

class _HomeCardFakeApi extends BulletinApi {
  _HomeCardFakeApi(this.page);

  final BulletinListPage page;
  int requests = 0;
  int failuresRemaining = 0;

  @override
  Future<BulletinListPage> fetchPage(Uri uri, {required int pageNumber}) async {
    requests++;
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw TimeoutException('DioException: 测试连接超时');
    }
    return page;
  }
}
