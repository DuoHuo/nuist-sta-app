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
      final dir = Directory('${tempDir.path}/$name');
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
    await BulletinApi.trimAttachmentCache(
      tempDir,
      preserve: preservedDir,
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
    expect(source, contains('coerceIn(320, 1600)'));
    expect(source, contains('Bitmap.CompressFormat.WEBP_LOSSY'));
    expect(source, contains('Bitmap.CompressFormat.WEBP'));
    expect(source, contains('bitmap.compress(format, 90, output)'));
    expect(source, isNot(contains('Bitmap.CompressFormat.PNG')));
  });
}
