import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/colors.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_api.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_attachment_preview.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_attachment_preview_dialog.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_detail_page.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_models.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_pdf_view.dart';

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

  testWidgets('无后缀的 Word 转换失败仍能预览正文并用识别出的类型外部打开', (tester) async {
    const mime =
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    final api = _FixtureApi(fixture('notice.data', [0x50, 0x4b, 3, 4]));
    final calls = <MethodCall>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_pdfChannel, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'officeMimeType') return mime;
      if (call.method == 'convertWord') {
        throw PlatformException(code: 'word_conversion_failed');
      }
      return {
        'mimeType': mime,
        'sections': [
          {
            'blocks': [
              {'text': '请在周五之前提交报名表', 'align': 'center', 'heading': 1},
              {
                'table': [
                  ['活动', '截止日期'],
                  ['比赛报名', '周五'],
                ],
              },
              {'image': _png},
            ],
          },
        ],
      };
    });
    await openDialog(tester, api);
    await _pumpUntil(tester, find.text('请在周五之前提交报名表'));
    final title = tester.widget<Text>(find.text('请在周五之前提交报名表'));
    expect(title.textAlign, TextAlign.center);
    expect(title.style?.fontWeight, FontWeight.w600);
    expect(find.widgetWithText(Table, '周五'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    await tester.tap(find.byTooltip(_openLabel));
    await tester.pumpAndSettle();
    expect(calls.map((call) => call.method), [
      'officeMimeType',
      'convertWord',
      'office',
    ]);
    expect(openCalls.single.arguments['mimeType'], mime);
    expect(api.downloads, 1);
  });

  testWidgets('DOCX 转成 PDF 后通过附件顶栏查找文字', (tester) async {
    final source = fixture('notice.docx', [0x50, 0x4b, 3, 4]);
    final converted = fixture('converted-word.pdf', ascii.encode('%PDF-1.4'));
    final calls = <MethodCall>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_pdfChannel, (
      call,
    ) async {
      calls.add(call);
      return switch (call.method) {
        'convertWord' => converted.path,
        'open' => {
          'id': 41,
          'pageAspectRatios': [.7],
        },
        'render' => _png,
        'searchPdf' => [
          {
            'page': 0,
            'rects': Float32List.fromList([.1, .1, .3, .2]),
          },
        ],
        _ => null,
      };
    });
    await openDialog(tester, _FixtureApi(source));
    final search = find.byTooltip('查找文字');
    await _pumpUntil(tester, search);
    expect(calls.first.arguments['path'], source.path);
    await tester.tap(search);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '报名');
    await tester.pump(const Duration(milliseconds: 180));
    await tester.pumpAndSettle();
    expect(find.text('1/1'), findsOneWidget);
    expect(
      calls.singleWhere((call) => call.method == 'searchPdf').arguments['path'],
      converted.path,
    );
    await tester.tap(find.byTooltip(_openLabel));
    await tester.pumpAndSettle();
    expect(openCalls.single.arguments['path'], source.path);
  });

  testWidgets('Excel 预览可以切换工作表并保留行列位置', (tester) async {
    final api = _FixtureApi(fixture('notice.xlsx', [0x50, 0x4b, 3, 4]));
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_pdfChannel, (
      _,
    ) async {
      return {
        'mimeType':
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'limited': true,
        'sections': [
          {
            'title': '报名',
            'columns': 2,
            'rows': [
              {
                'number': 3,
                'cells': ['', '实验班'],
              },
            ],
          },
          {
            'title': '排期',
            'columns': 1,
            'rows': [
              {
                'number': 7,
                'cells': ['周五'],
              },
            ],
          },
        ],
      };
    });
    await openDialog(tester, api);
    await _pumpUntil(tester, find.text('实验班'));
    expect(find.text('3'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
    expect(find.textContaining('仅预览部分内容'), findsOneWidget);

    await tester.tap(find.text('报名'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('排期').last);
    await tester.pumpAndSettle();
    expect(find.text('周五'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    expect(find.text('实验班'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('旧版 Excel 查找整本工作簿并高亮预览范围之外的结果', (tester) async {
    final file = fixture('notice.xls', [
      0xd0,
      0xcf,
      0x11,
      0xe0,
      0xa1,
      0xb1,
      0x1a,
      0xe1,
    ]);
    final queries = <MethodCall>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_pdfChannel, (
      call,
    ) async {
      if (call.method == 'office') {
        return {
          'mimeType': 'application/vnd.ms-excel',
          'limited': true,
          'sections': [],
        };
      }
      if (call.method != 'searchXls') return null;
      queries.add(call);
      final matchCase = call.arguments['matchCase'] as bool;
      return [
        {
          'title': '统计',
          'columns': 1,
          'count': matchCase ? 1 : 2,
          'rows': [
            {
              'number': 530,
              'cells': {0: 'ABC abc'},
              'highlights': {
                0: Int32List.fromList(matchCase ? [0, 3] : [0, 3, 4, 7]),
              },
            },
          ],
        },
      ];
    });
    await openDialog(tester, _FixtureApi(file), theme: appDarkTheme());
    final search = find.byTooltip('查找文字');
    await _pumpUntil(tester, search);
    final input = find.byType(TextField);
    expect(input, findsNothing);
    expect(
      tester
          .widget<AppBar>(find.byType(AppBar))
          .actions!
          .map((button) => (button as IconButton).tooltip),
      ['查找文字', _openLabel],
    );
    await tester.tap(search);
    await tester.pumpAndSettle();
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );
    await tester.enterText(input, 'ABC');
    await tester.pump(const Duration(milliseconds: 180));
    await tester.pumpAndSettle();
    expect(queries.single.arguments['path'], file.path);
    expect(find.text('共找到 2 项'), findsOneWidget);
    expect(find.text('1/2'), findsOneWidget);
    expect(find.text('530'), findsOneWidget);
    final richCell = tester.widget<Text>(find.text('ABC abc'));
    final matches = (richCell.textSpan! as TextSpan).children!.where(
      (span) => span.style?.backgroundColor != null,
    );
    expect(matches, hasLength(2));
    for (final (index, span) in matches.indexed) {
      final background = span.style!.backgroundColor!;
      final text = span.style!.color!;
      final backgroundLuminance = background.computeLuminance() + .05;
      final textLuminance = text.computeLuminance() + .05;
      if (index == 0) {
        expect(background, const Color(0xFFD21E39));
        expect(textLuminance / backgroundLuminance, greaterThan(5));
      } else {
        expect(background, const Color(0xFFFFEF00));
        expect(backgroundLuminance / textLuminance, greaterThan(7));
      }
    }
    await tester.tap(find.byTooltip('下一项'));
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);
    final newSpans =
        tester.widget<Text>(find.text('ABC abc')).textSpan! as TextSpan;
    expect(newSpans.children!.last.style!.decoration, TextDecoration.underline);
    await tester.tap(find.text('大小写敏感'));
    await tester.pump(const Duration(milliseconds: 180));
    await tester.pumpAndSettle();
    expect(queries.last.arguments['matchCase'], isTrue);
    expect(find.text('共找到 1 项'), findsOneWidget);
    expect(find.text('1/1'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭查找'));
    await tester.pumpAndSettle();
    expect(input, findsNothing);
    expect(find.text('530'), findsNothing);
    await tester.tap(search);
    await tester.pumpAndSettle();
    expect(find.text('共找到 0 项'), findsOneWidget);
    expect(find.text('ABC'), findsNothing);
  });

  testWidgets('XLSX 按序号跳到屏幕外的行列和工作表', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final file = fixture('jump.xlsx', [0x50, 0x4b, 3, 4]);
    final longCellPrefix = List.filled(45, '说明\n').join();
    final longCell = '$longCellPrefix目标55';
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_pdfChannel, (
      call,
    ) async {
      if (call.method == 'office') {
        return {
          'mimeType': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          'limited': true,
          'sections': [],
        };
      }
      if (call.method != 'searchXls') return null;
      return [
        {
          'title': '第一页',
          'columns': 16384,
          'rows': [
            for (var number = 1; number <= 60; number++)
              {
                'number': number,
                'cells': {
                  if (number == 55) 16383: longCell else 0: '目标$number',
                },
                'highlights': {
                  if (number == 55)
                    16383: Int32List.fromList([
                      longCellPrefix.length,
                      longCellPrefix.length + 2,
                    ])
                  else
                    0: Int32List.fromList([0, 2]),
                },
              },
          ],
        },
        {
          'title': '第二页',
          'columns': 1,
          'rows': [
            {
              'number': 80,
              'cells': {0: '目标61'},
              'highlights': {
                0: Int32List.fromList([0, 2]),
              },
            },
          ],
        },
      ];
    });
    await openDialog(tester, _FixtureApi(file));
    final search = find.byTooltip('查找文字');
    await _pumpUntil(tester, search);
    await tester.tap(search);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '目标');
    await tester.pump(const Duration(milliseconds: 180));
    await tester.pumpAndSettle();
    expect(find.text('1/61'), findsOneWidget);
    expect(find.text(longCell), findsNothing);

    Future<void> jump(String counter, String index) async {
      await tester.tap(find.text(counter));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), index);
      await tester.tap(find.text('跳转'));
      await tester.pumpAndSettle();
    }

    await jump('1/61', '55');
    expect(find.text('55/61'), findsOneWidget);
    expect(find.text('XFD').hitTestable(), findsOneWidget);
    final richText = find.descendant(
      of: find.text(longCell),
      matching: find.byType(RichText),
    );
    final paragraph = tester.renderObject<RenderParagraph>(richText);
    final match = paragraph
        .getBoxesForSelection(
          TextSelection(
            baseOffset: longCellPrefix.length,
            extentOffset: longCellPrefix.length + 2,
          ),
        )
        .single
        .toRect()
        .center;
    final viewport = RenderAbstractViewport.of(paragraph);
    final horizontal = RenderAbstractViewport.of(viewport.parent!);
    expect(
      viewport.paintBounds.contains(
        paragraph.localToGlobal(match, ancestor: viewport),
      ),
      isTrue,
    );
    expect(
      horizontal.paintBounds.contains(
        paragraph.localToGlobal(match, ancestor: horizontal),
      ),
      isTrue,
    );
    await tester.tap(find.byTooltip('上一项'));
    await tester.pumpAndSettle();
    expect(find.text('54/61'), findsOneWidget);
    expect(find.text('目标54').hitTestable(), findsOneWidget);

    await jump('54/61', '60');
    await tester.tap(find.byTooltip('下一项'));
    await tester.pumpAndSettle();
    expect(find.text('61/61'), findsOneWidget);
    expect(find.text('第二页'), findsWidgets);
    expect(find.text('目标61').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('由 Word 导出的 PDF 查找并跳到跨页命中', (tester) async {
    final file = fixture('converted.pdf', ascii.encode('%PDF-1.4'));
    final queries = <MethodCall>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_pdfChannel, (
      call,
    ) async {
      if (call.method == 'searchPdf') {
        queries.add(call);
        return [
          {
            'page': 0,
            'rects': Float32List.fromList([.1, .1, .2, .13]),
          },
          {
            'page': 0,
            'rects': Float32List.fromList([.25, .2, .35, .23]),
          },
          {
            'page': 2,
            'rects': Float32List.fromList([.2, .2, .5, .25]),
          },
        ];
      }
      return switch (call.method) {
        'open' => {
          'id': 12,
          'pageAspectRatios': [.7, .7, .7],
        },
        'render' => _png,
        _ => null,
      };
    });
    final document = await BulletinPdfDocument.open(file);
    var showSearch = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                TextButton(
                  onPressed: () => setState(() => showSearch = !showSearch),
                  child: const Text('切换搜索'),
                ),
                Expanded(
                  child: BulletinPdfView(
                    document: document,
                    firstPage: _png,
                    searchFile: file,
                    searchExpanded: showSearch,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('切换搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '明霜');
    await tester.pump(const Duration(milliseconds: 180));
    await tester.pumpAndSettle();
    expect(queries.single.arguments['query'], '明霜');
    expect(find.text('共找到 3 项'), findsOneWidget);
    expect(find.text('1/3'), findsOneWidget);
    final transform = tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!;
    final before = transform.value.clone();
    await tester.tap(find.byTooltip('下一项'));
    await tester.pumpAndSettle();
    expect(find.text('2/3'), findsOneWidget);
    expect(transform.value, before);

    await tester.tap(find.text('2/3'));
    await tester.pumpAndSettle();
    final ordinal = find.byType(TextFormField);
    await tester.enterText(ordinal, '4');
    await tester.tap(find.text('跳转'));
    await tester.pumpAndSettle();
    expect(find.text('请输入 1 到 3 之间的序号'), findsOneWidget);
    await tester.enterText(ordinal, '3');
    transform.value = Matrix4.diagonal3Values(2, 2, 2);
    await tester.tap(find.text('跳转'));
    await tester.pumpAndSettle();
    expect(find.text('3/3'), findsOneWidget);
    expect(transform.value.getMaxScaleOnAxis(), 2);
    expect(
      find.byWidgetPredicate((w) => w is Image && w.semanticLabel == '第 3 页'),
      findsOneWidget,
    );
    final highlightedPage = find.byWidgetPredicate(
      (w) =>
          w is CustomPaint &&
          w.foregroundPainter != null &&
          w.child is Image &&
          (w.child! as Image).semanticLabel == '第 3 页',
    );
    final painter = tester
        .firstWidget<CustomPaint>(highlightedPage)
        .foregroundPainter!;
    expect(
      (Canvas canvas) => painter.paint(canvas, const Size(100, 100)),
      paints
        ..something((methodName, arguments) {
          if (methodName != #drawRect) return false;
          final paint = arguments[1] as Paint;
          return paint.color.toARGB32() == 0x38C31932 &&
              paint.blendMode == BlendMode.multiply;
        })
        ..rect(
          color: const Color(0xFFC31932),
          style: PaintingStyle.stroke,
          strokeWidth: 3,
        ),
    );
    await tester.tap(find.text('切换搜索'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(highlightedPage, findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await document.close();
  });

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

  testWidgets('预览成功时只在顶栏保留打开图标，点击后复用已下载的文件', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final file = fixture('notice.txt', utf8.encode('附件里的中文内容'));
    final api = _FixtureApi(file);
    await openDialog(tester, api);
    await _pumpUntil(tester, find.text('附件里的中文内容'));
    expect(openCalls, isEmpty);
    expect(find.text(_openLabel), findsNothing);
    expect(find.text('分享'), findsNothing);
    expect(find.byTooltip('查找文字'), findsNothing);
    expect(
      find.descendant(of: find.byType(AppBar), matching: externalOpen()),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip(_openLabel));
    await tester.pumpAndSettle();
    expect(openCalls.single.method, 'open');
    expect(openCalls.single.arguments['path'], file.path);
    expect(api.downloads, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('不支持预览的附件等用户选择，加载中点击也只下载一次', (tester) async {
    final file = fixture('archive.zip', [0x50, 0x4b, 3, 4]);
    final api = _FixtureApi(file)..pending = Completer<File>();
    await openDialog(tester, api);
    await tester.tap(externalOpen());
    await tester.pump();
    expect(openCalls, isEmpty);
    api.pending!.complete(file);
    await _pumpUntil(tester, find.text(_unsupportedMessage));
    expect(find.text(_openLabel), findsOneWidget);
    expect(find.byTooltip(_openLabel), findsNothing);
    expect(openCalls.single.arguments['path'], file.path);
    expect(api.downloads, 1);
  });

  testWidgets('图片可缩放预览，等待用户选择打开方式', (tester) async {
    final api = _FixtureApi(fixture('image', _png));
    await openDialog(tester, api);
    await _pumpUntil(tester, find.byType(InteractiveViewer));
    expect(find.byType(Image), findsOneWidget);
    expect(openCalls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('图片无法解码时提示，并保留带文字的打开按钮', (tester) async {
    final api = _FixtureApi(fixture('bad.png', _png.take(16).toList()));
    await openDialog(tester, api);
    await _pumpUntil(tester, find.text(_unsupportedMessage));
    expect(openCalls, isEmpty);
    await tester.tap(find.text(_openLabel));
    await tester.pumpAndSettle();
    expect(openCalls.single.arguments['mimeType'], 'image/png');
    expect(api.downloads, 1);
  });

  testWidgets('PDF 上下连续滑动并按需渲染，关闭窗口后释放文档', (tester) async {
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
    final pdf = find.byType(InteractiveViewer);
    Finder page(String label) => find.byWidgetPredicate(
      (widget) => widget is Image && widget.semanticLabel == label,
    );
    await _pumpUntil(tester, page('第 1 页'));
    List<int> renderedPages() => [
      for (final call in calls)
        if (call.method == 'render') call.arguments['page'] as int,
    ];
    expect(renderedPages(), [0, 1]);
    expect(page('第 2 页'), findsNothing);
    await tester.drag(pdf, const Offset(0, -460));
    await _pumpUntil(tester, page('第 2 页'));
    expect(page('第 1 页'), findsOneWidget);
    expect(renderedPages().where((page) => page == 1), hasLength(1));
    expect(renderedPages(), isNot(contains(4)));
    expect(
      tester.getTopLeft(page('第 1 页')).dy,
      lessThan(tester.getTopLeft(page('第 2 页')).dy),
    );
    expect(find.byTooltip('上一页'), findsNothing);
    expect(find.byTooltip('下一页'), findsNothing);
    expect(openCalls, isEmpty);
    await tester.tap(find.byTooltip('关闭预览'));
    await tester.pumpAndSettle();
    expect(calls.where((call) => call.method == 'close'), hasLength(1));
  });

  for (final missingPlugin in [false, true]) {
    testWidgets('PDF ${missingPlugin ? '平台不支持预览' : '文件损坏'}时保留带文字的打开按钮', (
      tester,
    ) async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(_pdfChannel, (
        _,
      ) async {
        if (missingPlugin) throw MissingPluginException();
        throw PlatformException(code: 'preview_failed');
      });
      final api = _FixtureApi(fixture('notice', ascii.encode('%PDF-1.4')));
      await openDialog(tester, api);
      await _pumpUntil(tester, find.text(_unsupportedMessage));
      expect(openCalls, isEmpty);
      expect(find.text('分享'), findsNothing);
      await tester.tap(find.text(_openLabel));
      await tester.pumpAndSettle();
      expect(openCalls.single.arguments['mimeType'], 'application/pdf');
      expect(api.downloads, 1);
    });
  }

  testWidgets('下载失败可以重试，不把网络错误当成不支持的附件', (tester) async {
    final api = _FixtureApi(fixture('notice.txt', utf8.encode('重试成功')))
      ..fail = true;
    await openDialog(tester, api);
    await _pumpUntil(tester, find.textContaining('附件下载失败'));
    expect(openCalls, isEmpty);
    api.fail = false;
    await tester.tap(find.text(_openLabel));
    await _pumpUntil(tester, find.text('重试成功'));
    expect(api.downloads, 2);
    expect(openCalls.single.arguments['path'], api.file.path);
  });

  testWidgets('等待打开时关闭窗口，稍后下载完成也不会弹出应用选择器', (tester) async {
    final file = fixture('archive.zip', [0x50, 0x4b, 3, 4]);
    final api = _FixtureApi(file)..pending = Completer<File>();
    await openDialog(tester, api);
    expect(find.text('正在加载附件…'), findsOneWidget);
    await tester.tap(externalOpen());
    await tester.pump();
    await tester.tap(find.byTooltip('关闭预览'));
    await tester.pumpAndSettle();
    api.pending!.complete(file);
    await tester.pumpAndSettle();
    expect(openCalls, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
