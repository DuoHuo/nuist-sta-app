import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_api.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_detail_page.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_models.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_tagger.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

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
          api: BulletinApi(dio: dio),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('请提交申请材料。'), findsOneWidget);
    expect(find.text('申请表.pdf'), findsOneWidget);
    expect(find.text('点击预览，无法预览时下载'), findsOneWidget);
    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, '申请表.pdf')).onTap,
      isNotNull,
    );
  });

  group('公告附件下载文件名', () {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('bulletin-test-');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'getTemporaryDirectory') return directory.path;
        return null;
      });
    });

    tearDown(() async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      await for (final file in directory.list()) {
        await file.delete();
      }
      await directory.delete();
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
  });
}

class _BulletinAdapter implements HttpClientAdapter {
  _BulletinAdapter(this.body);

  final String body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(body, 200);

  @override
  void close({bool force = false}) {}
}
