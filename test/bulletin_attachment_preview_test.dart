import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/colors.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_api.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_attachment_preview.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_attachment_preview_dialog.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_detail_page.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_models.dart';

const _attachment = BulletinAttachment(
  name: '测试附件',
  url: 'https://bulletin.campus.invalid/system/_content/download.jsp?wbfileid=11',
);
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMwnvn/PwAFmQLLFOU//QAAAABJRU5ErkJggg==',
);
const _pdfChannel = MethodChannel('dev.duohuo.nuist_sta_app/attachment_pdf');

class _FixtureApi extends BulletinApi {
  _FixtureApi(this.file);

  final File file;
  int downloads = 0;
  bool fail = false;
  Completer<File>? pending;

  @override
  Future<File> downloadAttachment(BulletinAttachment attachment) async {
    downloads++;
    if (fail) throw const SocketException('测试断网');
    return pending == null ? file : pending!.future;
  }

  @override
  Future<BulletinDetailDocument?> fetchDetail(Bulletin bulletin) async =>
      const BulletinDetailDocument(
        blocks: [
          BulletinDetailBlock(
            kind: BulletinDetailBlockKind.paragraph,
            text: '公告正文',
          ),
        ],
        attachments: [_attachment],
      );
}

Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    if (finder.evaluate().isNotEmpty) {
      await tester.pumpAndSettle();
      return;
    }
  }
  expect(finder, findsWidgets);
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  File fixture(String name, List<int> bytes) =>
      File('${directory.path}${Platform.pathSeparator}$name')
        ..writeAsBytesSync(bytes);

  setUp(() {
    directory = Directory.systemTemp.createTempSync('bulletin-preview-');
  });

  tearDown(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_pdfChannel, null);
    await for (final file in directory.list()) {
      await file.delete();
    }
    await directory.delete();
  });

  test('没有扩展名的文件也按实际内容识别 PDF 和图片', () async {
    expect(
      await detectBulletinPreview(
        fixture('download', ascii.encode('%PDF-1.4')),
      ),
      BulletinPreviewKind.pdf,
    );
    expect(
      await detectBulletinPreview(fixture('download.jsp', _png)),
      BulletinPreviewKind.image,
    );
  });

  test('读取 UTF-8 和带 BOM 的 UTF-16 中文文本', () async {
    expect(
      await readBulletinPreviewText(fixture('utf8.txt', utf8.encode('公告内容'))),
      '公告内容',
    );
    for (final littleEndian in [true, false]) {
      final bytes = [
        if (littleEndian) ...[0xff, 0xfe] else ...[0xfe, 0xff],
      ];
      for (final unit in '公告内容'.codeUnits) {
        bytes.addAll(
          littleEndian ? [unit & 255, unit >> 8] : [unit >> 8, unit & 255],
        );
      }
      expect(
        await readBulletinPreviewText(fixture('utf16.txt', bytes)),
        '公告内容',
      );
    }
  });

  test('不支持的格式和过大的文本交给下载，短 RIFF 文本不会误判图片', () async {
    expect(
      await detectBulletinPreview(fixture('form.docx', [0x50, 0x4b, 3, 4])),
      BulletinPreviewKind.unsupported,
    );
    expect(
      await detectBulletinPreview(
        fixture('large.txt', List.filled(1024 * 1024 + 1, 65)),
      ),
      BulletinPreviewKind.unsupported,
    );
    expect(
      await detectBulletinPreview(fixture('small.txt', ascii.encode('RIFF'))),
      BulletinPreviewKind.text,
    );
  });

  Future<void> openDialog(
    WidgetTester tester,
    _FixtureApi api,
    Future<void> Function(File) save,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => BulletinAttachmentPreviewDialog(
                  attachment: _attachment,
                  api: api,
                  onDownload: save,
                ),
              ),
              child: const Text('打开附件'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开附件'));
    await tester.pump();
  }

  testWidgets('深色公告详情点击附件仍可预览，详情与预览窗口均保留深色配色', (tester) async {
    final api = _FixtureApi(fixture('notice.txt', utf8.encode('附件里的中文内容')));
    await tester.pumpWidget(
      MaterialApp(
        theme: appDarkTheme(),
        home: BulletinDetailPage(
          bulletin: const Bulletin(
            id: '1',
            title: '测试公告',
            url: 'https://bulletin.campus.invalid/info/1/1.htm',
            officialCategory: '其他',
            publisher: '测试单位',
            publishedAt: '2026-10-19',
          ),
          api: api,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      AppPalette.dark.pageBg,
    );
    final tile = tester.widget<ListTile>(find.widgetWithText(ListTile, '测试附件'));
    expect((tile.trailing! as Icon).color, AppPalette.dark.accent);
    await tester.tap(find.text('测试附件'));
    await _pumpUntil(tester, find.text('附件里的中文内容'));
    expect(find.text('附件预览'), findsOneWidget);
    final preview = find.byType(BulletinAttachmentPreviewDialog);
    expect(
      tester
          .widget<Scaffold>(
            find.descendant(of: preview, matching: find.byType(Scaffold)),
          )
          .backgroundColor,
      AppPalette.dark.pageBg,
    );
    expect(
      tester
          .widget<Text>(
            find.descendant(of: preview, matching: find.text('测试附件')),
          )
          .style
          ?.color,
      AppPalette.dark.titleText,
    );
    expect(api.downloads, 1);
    await tester.tap(find.byTooltip('关闭预览'));
    await tester.pumpAndSettle();
    expect(find.text('公告正文'), findsOneWidget);
  });

  testWidgets('文本预览后的手动下载复用文件，窄屏不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final file = fixture('notice.txt', utf8.encode('附件里的中文内容'));
    final api = _FixtureApi(file);
    final saved = <File>[];
    await openDialog(tester, api, (value) async => saved.add(value));
    await _pumpUntil(tester, find.text('附件里的中文内容'));
    expect(saved, isEmpty);
    await tester.tap(find.text('下载并分享'));
    await tester.pumpAndSettle();
    expect(saved.single.path, file.path);
    expect(api.downloads, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('不支持的附件提示后直接下载一次', (tester) async {
    final file = fixture('archive.zip', [0x50, 0x4b, 3, 4]);
    final api = _FixtureApi(file);
    final saved = <File>[];
    await openDialog(tester, api, (value) async => saved.add(value));
    await _pumpUntil(tester, find.textContaining('无法预览此附件，已为你下载'));
    expect(saved.single.path, file.path);
    expect(api.downloads, 1);
    await tester.pump();
    expect(saved, hasLength(1));
  });

  testWidgets('图片可缩放预览，不自动打开下载面板', (tester) async {
    final api = _FixtureApi(fixture('image', _png));
    final saved = <File>[];
    await openDialog(tester, api, (value) async => saved.add(value));
    await _pumpUntil(tester, find.byType(InteractiveViewer));
    expect(find.byType(Image), findsOneWidget);
    expect(saved, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('图片无法解码时自动下载且只提示一次', (tester) async {
    final api = _FixtureApi(fixture('bad.png', _png.take(16).toList()));
    var saves = 0;
    await openDialog(tester, api, (_) async => saves++);
    await _pumpUntil(tester, find.textContaining('无法预览此附件，已为你下载'));
    expect(saves, 1);
    expect(api.downloads, 1);
  });

  testWidgets('PDF 可翻页，关闭窗口后释放文档', (tester) async {
    final calls = <MethodCall>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_pdfChannel, (
      call,
    ) async {
      calls.add(call);
      return switch (call.method) {
        'open' => {'id': 7, 'pageCount': 2},
        'render' => _png,
        _ => null,
      };
    });
    final api = _FixtureApi(fixture('download.jsp', ascii.encode('%PDF-1.4')));
    var saves = 0;
    await openDialog(tester, api, (_) async => saves++);
    await _pumpUntil(tester, find.text('第 1 页 / 共 2 页'));
    await tester.tap(find.byTooltip('下一页'));
    await _pumpUntil(tester, find.text('第 2 页 / 共 2 页'));
    expect(
      calls
          .where((call) => call.method == 'render')
          .map((call) => call.arguments['page']),
      [0, 1],
    );
    expect(saves, 0);
    await tester.tap(find.byTooltip('关闭预览'));
    await tester.pumpAndSettle();
    expect(calls.where((call) => call.method == 'close'), hasLength(1));
  });

  for (final missingPlugin in [false, true]) {
    testWidgets('PDF ${missingPlugin ? '平台不支持' : '文件损坏'}时自动下载', (tester) async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(_pdfChannel, (
        _,
      ) async {
        if (missingPlugin) throw MissingPluginException();
        throw PlatformException(code: 'preview_failed');
      });
      final api = _FixtureApi(fixture('notice.pdf', ascii.encode('%PDF-1.4')));
      var saves = 0;
      await openDialog(tester, api, (_) async => saves++);
      await _pumpUntil(tester, find.textContaining('无法预览此附件，已为你下载'));
      expect(saves, 1);
      expect(api.downloads, 1);
    });
  }

  testWidgets('下载失败可以重试，不把网络错误当成不支持的附件', (tester) async {
    final api = _FixtureApi(fixture('notice.txt', utf8.encode('重试成功')))
      ..fail = true;
    var saves = 0;
    await openDialog(tester, api, (_) async => saves++);
    await _pumpUntil(tester, find.textContaining('附件下载失败'));
    expect(saves, 0);
    api.fail = false;
    await tester.tap(find.text('重新下载'));
    await _pumpUntil(tester, find.text('重试成功'));
    expect(api.downloads, 2);
  });

  testWidgets('加载中关闭窗口，稍后下载完成不会弹出保存面板', (tester) async {
    final file = fixture('archive.zip', [0x50, 0x4b, 3, 4]);
    final api = _FixtureApi(file)..pending = Completer<File>();
    var saves = 0;
    await openDialog(tester, api, (_) async => saves++);
    expect(find.text('正在加载附件…'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭预览'));
    await tester.pumpAndSettle();
    api.pending!.complete(file);
    await tester.pumpAndSettle();
    expect(saves, 0);
    expect(tester.takeException(), isNull);
  });
}
