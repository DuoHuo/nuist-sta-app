import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
const _actionsChannel = MethodChannel(
  'dev.duohuo.nuist_sta_app/attachment_actions',
);
const _unsupportedMessage = '无法预览此附件';
const _openLabel = '用其他应用打开';

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
  late List<MethodCall> openCalls;
  Finder externalOpen() => find.byIcon(Icons.open_in_new);

  File fixture(String name, List<int> bytes) =>
      File('${directory.path}${Platform.pathSeparator}$name')
        ..writeAsBytesSync(bytes);

  setUp(() {
    directory = Directory.systemTemp.createTempSync('bulletin-preview-');
    openCalls = [];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_actionsChannel, (
      call,
    ) async {
      openCalls.add(call);
      return null;
    });
  });

  tearDown(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_pdfChannel, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _actionsChannel,
      null,
    );
    await for (final file in directory.list()) {
      await file.delete();
    }
    await directory.delete();
  });

  test('没有扩展名的文件也识别 PDF 和图片的媒体类型', () async {
    expect(
      await detectBulletinPreview(
        fixture('download', ascii.encode('%PDF-1.4')),
      ),
      (kind: BulletinPreviewKind.pdf, mimeType: 'application/pdf'),
    );
    expect(await detectBulletinPreview(fixture('download.jsp', _png)), (
      kind: BulletinPreviewKind.image,
      mimeType: 'image/png',
    ));
  });

  test('旧版 Office 附件的复合文件签名会进入离线预览', () async {
    const signature = [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1];
    for (final (extension, mime) in [
      ('doc', 'application/msword'),
      ('xls', 'application/vnd.ms-excel'),
      ('ppt', 'application/vnd.ms-powerpoint'),
    ]) {
      expect(
        await detectBulletinPreview(fixture('office.$extension', signature)),
        (kind: BulletinPreviewKind.office, mimeType: mime),
      );
    }
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

  test('不支持预览压缩文件和过大的文本，短 RIFF 文本不会误判图片', () async {
    expect(
      (await detectBulletinPreview(fixture('archive.zip', [0x50, 0x4b, 3, 4])))
          .kind,
      BulletinPreviewKind.unsupported,
    );
    expect(
      (await detectBulletinPreview(
        fixture('large.txt', List.filled(1024 * 1024 + 1, 65)),
      )).kind,
      BulletinPreviewKind.unsupported,
    );
    expect(
      (await detectBulletinPreview(fixture('small.txt', ascii.encode('RIFF'))))
          .kind,
      BulletinPreviewKind.text,
    );
  });

  Future<void> openDialog(
    WidgetTester tester,
    _FixtureApi api, {
    ThemeData? theme,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => BulletinAttachmentPreviewDialog(
                  attachment: _attachment,
                  api: api,
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

  testWidgets('图片可缩放预览，无法解码时提示并保留打开按钮', (tester) async {
    final okApi = _FixtureApi(fixture('image', _png));
    await openDialog(tester, okApi);
    await _pumpUntil(tester, find.byType(InteractiveViewer));
    expect(find.byType(Image), findsOneWidget);
    expect(openCalls, isEmpty);
    await tester.tap(find.byTooltip('关闭预览'));
    await tester.pumpAndSettle();

    final badApi = _FixtureApi(fixture('bad.png', _png.take(16).toList()));
    await openDialog(tester, badApi);
    await _pumpUntil(tester, find.text(_unsupportedMessage));
    expect(openCalls, isEmpty);
    await tester.tap(find.text(_openLabel));
    await tester.pumpAndSettle();
    expect(openCalls.single.arguments['mimeType'], 'image/png');
    expect(badApi.downloads, 1);
  });

  testWidgets('PDF 上下连续滑动并按需渲染，关闭后释放文档；异常时保留打开按钮', (tester) async {
    tester.view.physicalSize = const Size(400, 650);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final calls = <MethodCall>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_pdfChannel, (
      call,
    ) async {
      calls.add(call);
      return switch (call.method) {
        'open' => {
          'id': 7,
          'pageAspectRatios': [0.5, 0.8, 0.7, 0.6, 1.0],
        },
        'render' => _png,
        _ => null,
      };
    });
    final api = _FixtureApi(fixture('download.jsp', ascii.encode('%PDF-1.4')));
    await openDialog(tester, api);
    Finder page(String label) => find.byWidgetPredicate(
      (widget) => widget is Image && widget.semanticLabel == label,
    );
    await _pumpUntil(tester, page('第 1 页'));
    await tester.drag(find.byType(InteractiveViewer), const Offset(0, -460));
    await _pumpUntil(tester, page('第 2 页'));
    expect(openCalls, isEmpty);
    await tester.tap(find.byTooltip('关闭预览'));
    await tester.pumpAndSettle();
    expect(calls.where((call) => call.method == 'close'), hasLength(1));

    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _pdfChannel,
      (_) async => throw PlatformException(code: 'preview_failed'),
    );
    final brokenApi = _FixtureApi(fixture('notice', ascii.encode('%PDF-1.4')));
    await openDialog(tester, brokenApi);
    await _pumpUntil(tester, find.text(_unsupportedMessage));
    await tester.tap(find.text(_openLabel));
    await tester.pumpAndSettle();
    expect(openCalls.single.arguments['mimeType'], 'application/pdf');
  });

  testWidgets('下载失败可重试，加载中关闭窗口不弹出应用选择器', (tester) async {
    final retryApi = _FixtureApi(fixture('notice.txt', utf8.encode('重试成功')))
      ..fail = true;
    await openDialog(tester, retryApi);
    await _pumpUntil(tester, find.textContaining('附件下载失败'));
    expect(openCalls, isEmpty);
    retryApi.fail = false;
    await tester.tap(find.text(_openLabel));
    await _pumpUntil(tester, find.text('重试成功'));
    await tester.tap(find.byTooltip('关闭预览'));
    await tester.pumpAndSettle();
    openCalls.clear();

    final file = fixture('wait.pdf', ascii.encode('%PDF-1.4'));
    final completerApi = _FixtureApi(file)..pending = Completer<File>();
    await openDialog(tester, completerApi);
    await tester.tap(externalOpen());
    await tester.pump();
    await tester.tap(find.byTooltip('关闭预览'));
    await tester.pumpAndSettle();
    completerApi.pending!.complete(file);
    await tester.pumpAndSettle();
    expect(openCalls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets('${dark ? '深色' : '浅色'}从公告详情点击附件进入预览支持 Android 预测性返回', (
      tester,
    ) async {
      final api = _FixtureApi(fixture('notice.txt', utf8.encode('附件里的中文内容')));
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? appDarkTheme() : appLightTheme(),
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
      await tester.tap(find.text('测试附件'));
      await _pumpUntil(tester, find.text('附件里的中文内容'));

      final route =
          ModalRoute.of(
                tester.element(find.byType(BulletinAttachmentPreviewDialog)),
              )!
              as PageRoute;
      expect(route.fullscreenDialog, isFalse);
      expect(route.popGestureEnabled, isTrue);

      ByteData? startResponse;
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/backgesture',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('startBackGesture', {
            'touchOffset': [5.0, 300.0],
            'progress': 0.0,
            'swipeEdge': 0,
          }),
        ),
        (data) => startResponse = data,
      );
      expect(
        const StandardMethodCodec().decodeEnvelope(startResponse!),
        isTrue,
      );
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/backgesture',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('updateBackGestureProgress', {
            'touchOffset': [40.0, 300.0],
            'progress': 0.4,
            'swipeEdge': 0,
          }),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
      expect(route.animation!.value, closeTo(0.6, 0.001));

      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/backgesture',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('cancelBackGesture', {
            'touchOffset': [5.0, 300.0],
            'progress': 0.0,
            'swipeEdge': 0,
          }),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
      expect(find.text('附件里的中文内容'), findsOneWidget);

      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/backgesture',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('startBackGesture', {
            'touchOffset': [5.0, 300.0],
            'progress': 0.0,
            'swipeEdge': 0,
          }),
        ),
        (_) {},
      );
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/backgesture',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('commitBackGesture', {
            'touchOffset': [80.0, 300.0],
            'progress': 0.8,
            'swipeEdge': 0,
          }),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
      expect(find.byType(BulletinAttachmentPreviewDialog), findsNothing);
      expect(find.text('公告正文'), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }
}
