import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_api.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_attachment_preview.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_attachment_preview_dialog.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_models.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_pdf_view.dart';

const _pdfChannel = MethodChannel('dev.duohuo.nuist_sta_app/attachment_pdf');
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMwnvn/PwAFmQLLFOU//QAAAABJRU5ErkJggg==',
);
// 200x100 横向 PNG（宽高比 2.0），用于验证未探测页渲染后修正布局高度。
final _landscapePng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAMgAAABkCAIAAABM5OhcAAABFklEQVR4nO3SQQkAMAzAwPo3vaoIg3KnII/Mg8D8DuAmY5EwFgljkTAWCWORMBYJY5EwFgljkTAWCWORMBYJY5EwFgljkTAWCWORMBYJY5EwFgljkTAWCWORMBYJY5EwFgljkTAWCWORMBYJY5EwFgljkTAWCWORMBYJY5EwFgljkTAWCWORMBYJY5EwFgljkTAWCWORMBYJY5EwFgljkTAWCWORMBYJY5EwFgljkTAWCWORMBYJY5EwFgljkTAWCWORMBYJY5EwFgljkTAWCWORMBYJY5EwFgljkTAWCWORMBYJY5EwFgljkTAWCWORMBYJY5EwFgljkTAWCWORMBYJY5EwFokFJhyDSNve8swAAAAASUVORK5CYII=',
);

class _FakeBulletinApi extends BulletinApi {
  _FakeBulletinApi(this.file);

  final File file;

  @override
  Future<File> downloadAttachment(BulletinAttachment attachment) async => file;
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
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('bulletin-s8-test-');
  });

  tearDown(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_pdfChannel, null);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('BulletinPdfDocument.renderPage 按需传递可选 width 参数', () async {
    final pdfFile = File('${tempDir.path}/sample.pdf')
      ..writeAsBytesSync(ascii.encode('%PDF-1.4'));
    final renderCalls = <Map<Object?, Object?>>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_pdfChannel, (
      call,
    ) async {
      return switch (call.method) {
        'open' => {
          'id': 9,
          'pageAspectRatios': [0.7, 0.7],
        },
        'render' => () {
          renderCalls.add(call.arguments as Map<Object?, Object?>);
          return _png;
        }(),
        _ => null,
      };
    });

    final doc = await BulletinPdfDocument.open(pdfFile);
    await doc.renderPage(0);
    await doc.renderPage(1, targetWidth: 1080);
    await doc.close();

    expect(renderCalls, hasLength(2));
    expect(renderCalls[0].containsKey('width'), isFalse);
    expect(renderCalls[0]['page'], 0);
    expect(renderCalls[1]['page'], 1);
    expect(renderCalls[1]['width'], 1080);
  });

  testWidgets(
    'BulletinAttachmentPreviewDialog 和 BulletinPdfView 传递视口缩放并限幅的 width',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final pdfFile = File('${tempDir.path}/dialog.pdf')
        ..writeAsBytesSync(ascii.encode('%PDF-1.4'));
      final renderWidths = <int?>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(_pdfChannel, (
        call,
      ) async {
        return switch (call.method) {
          'open' => {
            'id': 15,
            'pageAspectRatios': [0.5, 0.5],
          },
          'render' => () {
            final args = call.arguments as Map<Object?, Object?>;
            renderWidths.add(args['width'] as int?);
            return _png;
          }(),
          _ => null,
        };
      });

      const attachment = BulletinAttachment(
        name: '通知.pdf',
        url: 'https://bulletin.campus.invalid/a.pdf',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: BulletinAttachmentPreviewDialog(
            attachment: attachment,
            api: _FakeBulletinApi(pdfFile),
          ),
        ),
      );
      Finder page(String label) => find.byWidgetPredicate(
        (widget) => widget is Image && widget.semanticLabel == label,
      );
      await _pumpUntil(tester, page('第 1 页'));

      // 360 逻辑宽度 * 3.0 DPR = 1080（首页）；列表内页宽 (360 - 16) * 3.0 = 1032。
      expect(renderWidths, isNotEmpty);
      for (final width in renderWidths) {
        expect(width, isNotNull);
        expect(width, inInclusiveRange(320, 1600));
      }
      expect(renderWidths.first, 1080);
      if (renderWidths.length > 1) {
        expect(renderWidths[1], 1032);
      }
    },
  );

  testWidgets('BulletinPdfView 在极窄与超宽视口下将 width 限幅在 [320, 1600]', (
    tester,
  ) async {
    final pdfFile = File('${tempDir.path}/clamp.pdf')
      ..writeAsBytesSync(ascii.encode('%PDF-1.4'));
    final renderWidths = <int?>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_pdfChannel, (
      call,
    ) async {
      return switch (call.method) {
        'open' => {
          'id': 21,
          'pageAspectRatios': [0.5, 0.5],
        },
        'render' => () {
          final args = call.arguments as Map<Object?, Object?>;
          renderWidths.add(args['width'] as int?);
          return _png;
        }(),
        _ => null,
      };
    });

    final doc = await BulletinPdfDocument.open(pdfFile);

    // 极窄视口：宽度 200，DPR 1.0 -> 限幅到 320
    tester.view.physicalSize = const Size(200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BulletinPdfView(document: doc, firstPage: _png),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(renderWidths, contains(320));

    // 超宽视口：宽度 2400，DPR 2.0 -> 限幅到 1600
    renderWidths.clear();
    final docWide = await BulletinPdfDocument.open(pdfFile);
    tester.view.physicalSize = const Size(2400, 1600);
    tester.view.devicePixelRatio = 2.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BulletinPdfView(
            key: const ValueKey('wide'),
            document: docWide,
            firstPage: _png,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(renderWidths, contains(1600));

    await doc.close();
    await docWide.close();
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

  test('AttachmentPdfPreviewPlugin.kt 包含懒测前 8 页、视口限幅与 WebP 90 编码', () {
    final source = File(
      'android/app/src/main/kotlin/dev/duohuo/nuist_sta_app/AttachmentPdfPreviewPlugin.kt',
    ).readAsStringSync();

    expect(source, contains('INITIAL_PROBED_PAGES = 8'));
    expect(source, contains('min(renderer.pageCount, INITIAL_PROBED_PAGES)'));
    expect(source, contains('"probedPageCount" to probedCount'));
    expect(source, contains('coerceIn(320, 1600)'));
    expect(source, contains('Bitmap.CompressFormat.WEBP_LOSSY'));
    expect(source, contains('Bitmap.CompressFormat.WEBP'));
    expect(source, contains('bitmap.compress(format, 90, output)'));
    expect(source, isNot(contains('Bitmap.CompressFormat.PNG')));
  });

  test('BulletinPdfDocument.open 解析可选 probedPageCount 并兼容省略场景', () async {
    final pdfFile = File('${tempDir.path}/probed.pdf')
      ..writeAsBytesSync(ascii.encode('%PDF-1.4'));
    int? responseProbedCount = 2;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_pdfChannel, (
      call,
    ) async {
      if (call.method == 'open') {
        return {
          'id': 31,
          'pageAspectRatios': [0.7, 0.8, 0.7, 0.7],
          'probedPageCount': ?responseProbedCount,
        };
      }
      return null;
    });

    final docWithProbed = await BulletinPdfDocument.open(pdfFile);
    expect(docWithProbed.probedPageCount, 2);
    await docWithProbed.close();

    responseProbedCount = null;
    final docLegacy = await BulletinPdfDocument.open(pdfFile);
    expect(docLegacy.probedPageCount, 4);
    await docLegacy.close();
  });

  testWidgets('BulletinPdfView 在未探测页渲染横向图片后更新宽高比与布局高度，已探测页保持不变', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final pdfFile = File('${tempDir.path}/mixed.pdf')
      ..writeAsBytesSync(ascii.encode('%PDF-1.4'));
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_pdfChannel, (
      call,
    ) async {
      return switch (call.method) {
        'open' => {
          'id': 42,
          'pageAspectRatios': [1.0, 0.8, 0.5, 0.5],
          'probedPageCount': 2,
        },
        'render' => () {
          final page = (call.arguments as Map<Object?, Object?>)['page'] as int;
          // 模拟第 1 页（已探测）与第 2、3 页（未探测）都返回 200x100 横向图，
          // 检验只有未探测页会更新布局比例。
          return page >= 1 ? _landscapePng : _png;
        }(),
        _ => null,
      };
    });

    final doc = await BulletinPdfDocument.open(pdfFile);
    expect(doc.probedPageCount, 2);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BulletinPdfView(document: doc, firstPage: _png),
        ),
      ),
    );

    Finder pageImage(String label) => find.byWidgetPredicate(
      (widget) => widget is Image && widget.semanticLabel == label,
    );
    await _pumpUntil(tester, pageImage('第 4 页'));

    // 视图宽 400、左右边距各 8 -> 页宽 384：
    // - 第 2 页（index=1 < probedPageCount=2）保持已探测比例 0.8 -> 高度 384 / 0.8 = 480。
    // - 第 3 页（index=2 >= probedPageCount=2）更新为 200x100 比例 2.0 -> 高度 384 / 2.0 = 192。
    // - 第 4 页（index=3）受前页收窄影响，纵向偏移从 1664 上移到 8 + 384 + 8 + 480 + 8 + 192 + 8 = 1088。
    expect(
      tester.getSize(find.byKey(const ValueKey(1))).width,
      closeTo(384.0, 0.01),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey(1))).height,
      closeTo(480.0, 0.01),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey(2))).width,
      closeTo(384.0, 0.01),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey(2))).height,
      closeTo(192.0, 0.01),
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey(3))).dy,
      closeTo(1088.0, 0.01),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey(3))).height,
      closeTo(192.0, 0.01),
    );

    // 无效/占位字节在未探测页渲染时不会抛出异常，且保留初始宽高比。
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_pdfChannel, (
      call,
    ) async {
      return switch (call.method) {
        'open' => {
          'id': 43,
          'pageAspectRatios': [1.0, 0.5],
          'probedPageCount': 1,
        },
        'render' => Uint8List.fromList([1, 2, 3, 4]),
        _ => null,
      };
    });
    final invalidDoc = await BulletinPdfDocument.open(pdfFile);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BulletinPdfView(document: invalidDoc, firstPage: _png),
        ),
      ),
    );
    await _pumpUntil(tester, find.text('此页无法预览'));
    expect(
      tester.getSize(find.byKey(const ValueKey(1))).height,
      closeTo(768.0, 0.01),
    );
    expect(tester.takeException(), isNull);

    await doc.close();
    await invalidDoc.close();
  });
}
