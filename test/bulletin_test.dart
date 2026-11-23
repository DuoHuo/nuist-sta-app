import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/app_directories.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/core/config/campus_config.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_api.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_controller.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_detail_page.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_models.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_page.dart';
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

  for (final target in [
    'https://outside.example.test/article',
    'http://${CampusHosts.bulletin}/article',
    'https://${CampusHosts.bulletin}:8443/article',
  ]) {
    test('公告跳转离开官网允许原点时返回网页入口', () async {
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
      );
      expect(adapter.requests, hasLength(1));
    });
  }

  test('订阅主题共 14 个，且默认关闭', () {
    expect(BulletinTopic.values, hasLength(14));
    const subscription = BulletinSubscription();
    expect(subscription.enabled, isFalse);
    expect(subscription.topics, isEmpty);
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

  test('解析官网列表、分类、发布单位和下一页地址', () {
    const html = '''
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

    final page = parseBulletinPage(
      html,
      currentUri: Uri.parse('https://bulletin.campus.invalid/'),
      pageNumber: 1,
    );

    expect(page.items, hasLength(1));
    expect(page.items.single.id, '12345');
    expect(page.items.single.officialCategory, '学术报告');
    expect(page.items.single.publisher, '科研处');
    expect(page.items.single.topics, contains(BulletinTopic.academicTalks));
    expect(page.totalCount, 100);
    expect(page.nextUrl, 'https://bulletin.campus.invalid/index_2.htm');
  });

  testWidgets('公告详情展示正文外的附件下载入口', (tester) async {
    final dio = Dio()
      ..httpClientAdapter = _BulletinAdapter('''
        <div class="article">
          <div class="wp_articlecontent"><p>请提交申请材料。</p></div>
          <ul><li>附件【<a href="/system/_content/download.jsp?urltype=news.DownloadAttachUrl&amp;wbfileid=11">申请表.pdf</a>】已下载0次</li></ul>
        </div>
      ''');
    addTearDown(() => dio.close(force: true));
    final api = _AwaitableBulletinApi(dio: dio);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: BulletinDetailPage(
            bulletin: const Bulletin(
              id: '123',
              title: '测试公告',
              url: 'https://bulletin.campus.invalid/info/1/123.htm',
              officialCategory: '其他',
              publisher: '测试单位',
              publishedAt: '2026-10-19',
            ),
            api: api,
          ),
        ),
      );
      await api.detail;
    });
    await tester.pumpAndSettle();

    expect(find.text('请提交申请材料。'), findsOneWidget);
    expect(find.text('申请表.pdf'), findsOneWidget);
    expect(find.text('点击查看附件'), findsOneWidget);
    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, '申请表.pdf')).onTap,
      isNotNull,
    );
  });

  test('接口后台解析列表与长正文，保留分页、附件和网页兜底', () async {
    final uri = Uri.parse('https://bulletin.campus.invalid/');
    const listHtml = '''
      <ul><li class="news">
        <a href="/info/1001/12345.htm">专题学术报告通知</a>
        <span class="wjj">[学术报告]</span>
        <span class="news_org">测试单位</span>
        <span class="news_date">2026-09-27</span>
      </li></ul>
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

  testWidgets('公告标题和正文长按后只显示中文复制和全选', (tester) async {
    final copied = _captureClipboard();
    await tester.pumpWidget(
      MaterialApp(
        home: BulletinDetailPage(
          bulletin: const Bulletin(
            id: 'copy',
            title: 'NoticeTitle',
            url: 'https://bulletin.campus.invalid/info/copy.htm',
            officialCategory: '其他',
            publisher: '',
            publishedAt: '',
          ),
          api: _DocumentBulletinApi(
            const BulletinDetailDocument(
              blocks: [
                BulletinDetailBlock(
                  kind: BulletinDetailBlockKind.paragraph,
                  text: 'CopyTarget',
                ),
              ],
              attachments: [],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final value in ['NoticeTitle', 'CopyTarget']) {
      final target = find.text(value);
      await tester.longPressAt(
        tester.getTopLeft(target) + const Offset(12, 10),
      );
      await tester.pumpAndSettle();
      final toolbar = tester.widget<AdaptiveTextSelectionToolbar>(
        find.byType(AdaptiveTextSelectionToolbar),
      );
      expect(toolbar.buttonItems!.map((item) => item.label), ['复制', '全选']);
      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();
      expect(copied.last, value);
    }
    expect(copied, ['NoticeTitle', 'CopyTarget']);
  });

  testWidgets('复制全文包含未渲染的段落、名单与表格，排除附件按钮文案', (tester) async {
    final copied = _captureClipboard();
    final items = List.generate(200, (i) => '合成名单条目 $i');
    await tester.pumpWidget(
      MaterialApp(
        home: BulletinDetailPage(
          bulletin: const Bulletin(
            id: 'copy-all',
            title: '名单公告',
            url: 'https://bulletin.campus.invalid/info/copy-all.htm',
            officialCategory: '其他',
            publisher: '测试单位',
            publishedAt: '2026-11-13',
          ),
          api: _DocumentBulletinApi(
            BulletinDetailDocument(
              blocks: [
                const BulletinDetailBlock(
                  kind: BulletinDetailBlockKind.paragraph,
                  text: '请核对下面的名单。',
                ),
                BulletinDetailBlock(
                  kind: BulletinDetailBlockKind.numberedList,
                  items: items,
                ),
                const BulletinDetailBlock(
                  kind: BulletinDetailBlockKind.table,
                  items: ['事项  ·  时间', '材料领取  ·  上午'],
                ),
                const BulletinDetailBlock(
                  kind: BulletinDetailBlockKind.paragraph,
                  text: '正文结束',
                ),
              ],
              attachments: const [
                BulletinAttachment(
                  name: '名单说明.pdf',
                  url: 'https://bulletin.campus.invalid/files/example.pdf',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('正文结束', skipOffstage: false), findsNothing);

    await tester.tap(find.byTooltip('复制全文'));
    await tester.pumpAndSettle();
    final fullText = [
      '名单公告',
      '测试单位 · 2026-11-13',
      '请核对下面的名单。',
      [for (final (i, item) in items.indexed) '${i + 1}. $item'].join('\n'),
      '事项  ·  时间\n材料领取  ·  上午',
      '正文结束',
    ].join('\n\n');
    expect(copied.single, fullText);
    expect(find.text('全文已复制'), findsOneWidget);

    final firstParagraph = find.text('请核对下面的名单。');
    final paragraphTextPoint =
        tester.getTopLeft(firstParagraph) + const Offset(12, 10);
    await tester.longPressAt(paragraphTextPoint);
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    final toolbar = tester.widget<AdaptiveTextSelectionToolbar>(
      find.byType(AdaptiveTextSelectionToolbar),
    );
    expect(toolbar.buttonItems!.map((item) => item.label), ['复制']);
    expect(find.text('正文结束', skipOffstage: false), findsNothing);
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(copied, [fullText, fullText]);

    await tester.longPressAt(paragraphTextPoint);
    await tester.pumpAndSettle();
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('全选'), findsOneWidget);

    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    final lastParagraph = find.text('正文结束');
    await tester.scrollUntilVisible(lastParagraph, 500, maxScrolls: 100);
    await tester.pumpAndSettle();
    final renderedParagraph = tester.widget<RichText>(
      find.descendant(of: lastParagraph, matching: find.byType(RichText)),
    );
    expect(renderedParagraph.text.style?.backgroundColor, isNotNull);
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(copied, [fullText, fullText, fullText]);
  });

  for (final dark in [false, true]) {
    for (final kind in [
      BulletinDetailBlockKind.bulletList,
      BulletinDetailBlockKind.numberedList,
      BulletinDetailBlockKind.table,
    ]) {
      testWidgets('长公告逐行挂载并保留末尾附件：$kind，dark=$dark', (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 1.5;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final api = _DocumentBulletinApi(
          BulletinDetailDocument(
            blocks: [
              const BulletinDetailBlock(
                kind: BulletinDetailBlockKind.heading,
                text: '正文标题',
              ),
              BulletinDetailBlock(
                kind: kind,
                items: List.generate(200, (index) => '合成名单条目 $index'),
              ),
              const BulletinDetailBlock(
                kind: BulletinDetailBlockKind.paragraph,
                text: '正文结束',
              ),
            ],
            attachments: const [
              BulletinAttachment(
                name: '名单说明.pdf',
                url: 'https://bulletin.campus.invalid/files/example.pdf',
              ),
            ],
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? appDarkTheme() : appLightTheme(),
            home: BulletinDetailPage(
              bulletin: const Bulletin(
                id: 'synthetic-long',
                title: '测试公告',
                url: 'https://bulletin.campus.invalid/info/long.htm',
                officialCategory: '其他',
                publisher: '测试单位',
                publishedAt: '2026-11-07',
              ),
              api: api,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('正文标题'), findsOneWidget);
        expect(find.text('合成名单条目 0'), findsOneWidget);
        expect(find.text('合成名单条目 199', skipOffstage: false), findsNothing);
        expect(
          find
              .byWidgetPredicate(
                (widget) =>
                    widget is Text &&
                    (widget.data?.startsWith('合成名单条目') ?? false),
                skipOffstage: false,
              )
              .evaluate()
              .length,
          lessThan(30),
        );
        await tester.scrollUntilVisible(
          find.text('名单说明.pdf'),
          500,
          maxScrolls: 100,
        );
        await tester.pumpAndSettle();
        expect(find.text('正文结束'), findsOneWidget);
        expect(find.text('合成名单条目 199'), findsOneWidget);
        expect(find.text('合成名单条目 0', skipOffstage: false), findsNothing);
        expect(find.text('测试公告', skipOffstage: false), findsNothing);
        expect(
          find.text('测试单位 · 2026-11-07', skipOffstage: false),
          findsNothing,
        );
        if (kind == BulletinDetailBlockKind.numberedList) {
          expect(find.text('200.'), findsOneWidget);
        }
        expect(find.text('名单说明.pdf').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

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

  testWidgets('BulletinPage 长列表按需懒构建且支持搜索过滤与分类切换', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final allCategory = BulletinCategory.all.first;
    final docCategory = BulletinCategory.all[1];
    final longItems = List.generate(
      80,
      (i) => Bulletin(
        id: 'item-$i',
        title: i == 75 ? 'SpecialNotice Beta' : '合成公告 $i',
        url: 'https://bulletin.campus.invalid/info/1/$i.htm',
        officialCategory: '通知',
        publisher: i == 42 ? 'AlphaLab' : '测试单位',
        publishedAt: '2026-10-01',
      ),
    );
    const docItems = [
      Bulletin(
        id: 'doc-1',
        title: '文件公告条目 1',
        url: 'https://bulletin.campus.invalid/info/2/1.htm',
        officialCategory: '文件公告',
        publisher: '校办',
        publishedAt: '2026-10-02',
      ),
    ];

    final api = _PagedFixtureApi({
      allCategory.uri.toString(): BulletinListPage(
        items: longItems,
        pageNumber: 1,
      ),
      docCategory.uri.toString(): const BulletinListPage(
        items: docItems,
        pageNumber: 1,
      ),
    });
    final controller = BulletinController(api: api, store: _MemoryStore());
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: BulletinPage(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.text('合成公告 0'), findsOneWidget);
    expect(find.text('合成公告 79', skipOffstage: false), findsNothing);

    // 大小写不敏感匹配标题与发布单位。
    await tester.enterText(find.byType(TextField), 'specialnotice');
    await tester.pump();
    expect(find.text('SpecialNotice Beta'), findsOneWidget);
    expect(find.text('合成公告 0'), findsNothing);

    await tester.enterText(find.byType(TextField), 'alphalab');
    await tester.pump();
    expect(find.text('合成公告 42'), findsOneWidget);
    expect(find.text('SpecialNotice Beta'), findsNothing);

    await tester.tap(find.byTooltip('清空搜索'));
    await tester.pump();
    expect(find.text('合成公告 0'), findsOneWidget);

    // 切换分类后展示新分类条目，再切回全部分类继续验证滚动懒加载。
    await tester.tap(find.widgetWithText(ChoiceChip, docCategory.name));
    await tester.pumpAndSettle();
    expect(find.text('文件公告条目 1'), findsOneWidget);
    expect(find.text('合成公告 0'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, allCategory.name));
    await tester.pumpAndSettle();
    expect(find.text('合成公告 0'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('合成公告 79'),
      600,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('合成公告 79'), findsOneWidget);
    expect(find.text('已经看到当前分类的全部公告'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

List<String> _captureClipboard() {
  final copied = <String>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      copied.add((call.arguments as Map)['text'] as String);
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return copied;
}

class _AwaitableBulletinApi extends BulletinApi {
  _AwaitableBulletinApi({required super.dio});

  Future<BulletinDetailDocument?>? detail;

  @override
  Future<BulletinDetailDocument?> fetchDetail(Bulletin bulletin) =>
      detail = super.fetchDetail(bulletin);
}

class _DocumentBulletinApi extends BulletinApi {
  _DocumentBulletinApi(this.document);

  final BulletinDetailDocument document;

  @override
  Future<BulletinDetailDocument?> fetchDetail(Bulletin bulletin) async =>
      document;
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
