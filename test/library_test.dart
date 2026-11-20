import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/config/campus_config.dart';
import 'package:nuist_sta_app/core/logging/app_log.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/library/library_api.dart';
import 'package:nuist_sta_app/mini_apps/library/library_book_cover.dart';
import 'package:nuist_sta_app/mini_apps/library/library_book_info_card.dart';
import 'package:nuist_sta_app/mini_apps/library/library_models.dart';
import 'package:nuist_sta_app/mini_apps/library/library_page.dart';

class _CatalogueAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(options, requestStream, cancelFuture) async {
    requests.add(options);
    await requestStream?.drain<void>();
    return ResponseBody.fromString(
      responseJson(options.uri.path),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  static String responseJson(String path) {
    final data = switch (path) {
      '/meta-local/opac/search/' => {
        'total': 2,
        'dataList': [
          {
            'bibId': 'mock-book',
            'title': '测试馆藏',
            'publisher': '测试出版社',
            'callno': ['P4/24'],
            'itemCount': 2,
            'circCount': 1,
          },
        ],
      },
      '/meta-local/opac/bibs/mock-book/holdings' => {
        'holdings': jsonEncode([
          {
            'library': '测试总馆',
            'locationName': '三楼北',
            'status': '可借',
            'callNo': 'P4/24',
          },
          {
            'library': '测试总馆',
            'locationName': '二楼南',
            'status': '借出',
            'callNo': 'P4/24',
            'shelfMark': 'A12',
          },
        ]),
      },
      '/meta-local/opac/bibs/mock-book/infos' => {
        'map': {
          'baseInfo': {
            'map': {
              'isbn': '978-7-03-022595-5',
              'title': '测试馆藏',
              'author': '甲作者, 乙作者, 丙作者编著',
            },
          },
          'detailInfo': {
            'map': {
              '出版发行项': "北京:<a style='color:#006fcc' href='{meta}/#/search?query=publisher'>测试出版社</a>,2021",
              '题名/责任者': '测试馆藏/甲作者, 乙作者, 丙作者编著',
              '个人责任者': '<a href="/author">甲作者</a> 乙作者 丙作者 编著 编著 编著',
              'ISBN及定价': '978-7-03-022595-5/CNY89.00',
              '中图法分类号': 'TP301.6',
              '载体形态项': 'xii, 318页:图，表; 26cm',
              '学科主题': ['<a href="/subject">程序设计</a>', '算法&nbsp;基础'],
              '并列正题名': 'Sample title',
              '其他题名': '隐藏的其他题名',
              '提要文摘附注': '第一&#x7AE0;<br>第二章',
              '版本说明': '三人编著，测试版',
            },
          },
        },
      },
      '/meta-local/opac/search/extend3' => {
        'mock-book': [
          {'imageUrl': 'https://example.invalid/other.jpg'},
          {'imageUrl': '//img3m2.ddimg.cn/missing.jpg'},
          {'imageUrl': '//img.hwlsp.cn/available.jpg'},
        ],
      },
      _ => throw StateError('意外的馆藏请求'),
    };
    return jsonEncode({'code': 0, 'data': data});
  }

  @override
  void close({bool force = false}) {}
}

class _LibraryApi extends LibraryApi {
  _LibraryApi({super.catalogue, super.coverImages, this.loanPage});

  final Future<LibraryResultPage<LibraryLoan>>? loanPage;

  @override
  Future<bool> hasPortalBinding() async => loanPage != null;

  @override
  Future<LibraryResultPage<LibraryLoan>> fetchLoans(
    int page, {
    CancelToken? cancelToken,
  }) => loanPage ?? super.fetchLoans(page, cancelToken: cancelToken);
}

final _fakeCover = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgYAAAAAMAAWgmWQ0AAAAASUVORK5CYII=',
);

void _mockImages(Dio dio, List<RequestOptions> requests) {
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        requests.add(options);
        if (options.path.endsWith('missing.jpg')) {
          handler.reject(
            DioException.badResponse(
              statusCode: 404,
              requestOptions: options,
              response: Response<void>(
                requestOptions: options,
                statusCode: 404,
              ),
            ),
          );
          return;
        }
        handler.resolve(
          Response<ResponseBody>(
            requestOptions: options,
            statusCode: 200,
            data: ResponseBody.fromBytes(_fakeCover, 200),
            headers: Headers.fromMap({
              Headers.contentTypeHeader: ['image/png'],
            }),
          ),
        );
      },
    ),
  );
}

void main() {
  late Dio dio;
  late Dio images;
  late _CatalogueAdapter adapter;
  setUp(() {
    adapter = _CatalogueAdapter();
    dio = Dio()..httpClientAdapter = adapter;
    images = Dio();
  });
  tearDown(() {
    AppLog.recordListenerForTesting = null;
    dio.close(force: true);
    images.close(force: true);
  });

  test('公开检索传递字段和页码，日志遮蔽检索词', () async {
    final records = <Map<String, Object?>>[];
    AppLog.recordListenerForTesting = records.add;
    final result = await LibraryApi(catalogue: dio)
        .search('私人检索测试词', LibrarySearchField.isbn, 2);
    final request = adapter.requests.single;
    expect(request.uri.host, CampusHosts.library);
    expect(request.method, 'POST');
    expect(request.headers.containsKey('cookie'), isFalse);
    expect(request.data['page'], 2);
    expect(request.data['queryFieldList'], [
      {
        'logic': 0,
        'field': 'isbns',
        'values': ['私人检索测试词'],
        'operator': '=',
      },
    ]);
    expect(result.items.single.availableCount, 1);
    final diagnostics = jsonEncode(records);
    expect(diagnostics, contains('REDACTED_PERSONAL'));
    expect(diagnostics, contains('测试馆藏'));
    expect(diagnostics, isNot(contains('私人检索测试词')));
  });

  test('借阅接口报错或缺失列表时不会展示为无借阅', () {
    expect(
      () => libraryResponseData({'code': 410, 'data': {}}),
      throwsFormatException,
    );
    expect(
      () => libraryResultPage({'total': 0}, 'items', LibraryLoan.fromJson),
      throwsFormatException,
    );
    final empty = libraryResultPage(
      {'total': 0, 'items': []},
      'items',
      LibraryLoan.fromJson,
    );
    expect(empty.items, isEmpty);
  });

  test('从编目字段提取纯文本，并按 ISBN 查询安全的可用封面', () async {
    final imageRequests = <RequestOptions>[];
    _mockImages(images, imageRequests);
    final api = LibraryApi(catalogue: dio, coverImages: images);
    final token = CancelToken();
    final book = await api.fetchBookInfo('mock-book', token);
    expect(book.fields['出版发行项'], '北京:测试出版社,2021');
    expect(book.fields['学科主题'], '程序设计、算法 基础');
    expect(book.fields['提要文摘附注'], '第一章\n第二章');
    expect(book.author, '甲作者, 乙作者, 丙作者');
    expect(book.fields.values, everyElement(isNot(contains('编著'))));
    expect(book.price, '¥ 89.00');
    expect(book.pageCount, '318页');
    final cover = await api.fetchCover('mock-book', book.isbns, token);
    expect(adapter.requests.last.uri.queryParameters, {'coversOnly': 'true'});
    expect(adapter.requests.last.data, {
      'isbns': ['978-7-03-022595-5'],
      'bibIds': ['mock-book'],
    });
    expect(imageRequests.map((request) => request.uri.host), [
      'img3m2.ddimg.cn',
      'img.hwlsp.cn',
    ]);
    for (final request in imageRequests) {
      expect(request.uri.scheme, 'https');
      expect(request.followRedirects, isFalse);
      expect(request.headers['Cookie'], isNull);
    }
    expect(cover, _fakeCover);
  });

  test('页数只取明确的页码标注，略过没有页数的载体描述', () {
    for (final (fields, expected) in [
      ({'载体形态项': '1册:彩色插图; 26cm'}, null),
      ({'载体形态项': '12页图版'}, null),
      ({'载体形态项': 'xii, 380 p. : ill. ; 24 cm'}, '380页'),
      ({'载体形态': '１０４５ 頁'}, '1045页'),
      ({'载体形态项': '1册', '页数': '230'}, '230页'),
    ]) {
      final book = LibraryBookInfo.fromJson({
        'map': {
          'detailInfo': {'map': fields},
        },
      });
      expect(book.pageCount, expected);
    }
  });

  test('校方返回空封面时不请求图片', () async {
    final imageRequests = <RequestOptions>[];
    _mockImages(images, imageRequests);
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.resolve(
          Response<String>(
            requestOptions: options,
            statusCode: 200,
            data: '{"code":0,"data":null}',
          ),
        ),
      ),
    );
    final cover = await LibraryApi(
      catalogue: dio,
      coverImages: images,
    ).fetchCover('mock-book', ['978-7-03-022595-5'], CancelToken());
    expect(cover, isNull);
    expect(imageRequests, isEmpty);
  });

  test('方形封面只裁对称的左右白边，保留完整上下边缘', () {
    const side = 100;
    final pixels = ByteData(side * side * 4);
    void fill({required bool fullHeight, int rightMargin = 20}) {
      for (var y = 0; y < side; y++) {
        for (var x = 0; x < side; x++) {
          final inside =
              x >= 20 &&
              x < side - rightMargin &&
              (fullHeight || (y >= 10 && y < 90));
          pixels.setUint32(
            (y * side + x) * 4,
            inside ? 0x203040ff : 0xffffffff,
          );
        }
      }
    }

    fill(fullHeight: true);
    expect(
      paddedCoverSourceRect(pixels, side),
      const Rect.fromLTRB(18, 0, 82, 100),
    );
    fill(fullHeight: false);
    expect(paddedCoverSourceRect(pixels, side), isNull);
    fill(fullHeight: true, rightMargin: 5);
    expect(paddedCoverSourceRect(pixels, side), isNull);
  });

  testWidgets('能打开馆藏详情，未绑定时只请求公开馆藏', (tester) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final paths = <String>[];
    final detailReady = Completer<void>();
    final copiedIsbns = <Object?>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copiedIsbns.add(call.arguments);
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    _mockImages(images, []);
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          paths.add(options.uri.path);
          if (options.uri.path.contains('/bibs/')) {
            await detailReady.future;
          }
          handler.resolve(
            Response<String>(
              requestOptions: options,
              statusCode: 200,
              data: _CatalogueAdapter.responseJson(options.uri.path),
            ),
          );
        },
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryPage(
          api: _LibraryApi(catalogue: dio, coverImages: images),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '测试');
    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    expect(find.text('共 2 条书目'), findsOneWidget);
    expect(find.text('可借 1 册'), findsOneWidget);

    await tester.tap(find.text('测试馆藏'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(CircularProgressIndicator), findsNWidgets(2));
    expect(find.byType(LinearProgressIndicator), findsNothing);
    detailReady.complete();
    await tester.pumpAndSettle();
    expect(find.text('馆藏详情'), findsOneWidget);
    expect(find.text('书目信息'), findsNothing);
    expect(find.text('测试馆藏'), findsOneWidget);
    expect(find.textContaining('编著'), findsNothing);
    expect(find.byType(Table), findsOneWidget);
    expect(
      tester.widget<Table>(find.byType(Table)).children,
      everyElement(
        isA<TableRow>().having((row) => row.children.length, '列数', 2),
      ),
    );
    final table = tester.getRect(find.byType(Table));
    final classification = tester.getTopLeft(find.text('中图法分类号')).dy;
    final isbn = tester.getTopLeft(find.text('ISBN')).dy;
    final pageCount = tester.getTopLeft(find.text('页数')).dy;
    final firstRowHeight = isbn - classification;
    expect(isbn, closeTo(pageCount, 0.1));
    expect(table.height - firstRowHeight, closeTo(firstRowHeight, 0.1));
    expect(firstRowHeight, lessThan(49));
    expect(find.text('318页'), findsOneWidget);
    expect(find.text('载体形态'), findsNothing);
    expect(find.textContaining('26cm'), findsNothing);
    final copy = find.byTooltip('复制 ISBN');
    final copyIcon = tester.getCenter(find.byIcon(Icons.content_copy_outlined));
    expect(copyIcon, tester.getCenter(copy));
    expect(copyIcon.dy, closeTo(tester.getCenter(find.text('ISBN')).dy, 3));
    expect(find.byType(LibraryBookCover), findsOneWidget);
    final bookTitle = tester.widget<Text>(find.text('测试馆藏'));
    expect(bookTitle.style?.fontSize, 20);
    final parallelTitle = find.text('并列正题名');
    final abstract = find.text('内容提要');
    expect(
      tester.getTopLeft(parallelTitle).dy,
      lessThan(tester.getTopLeft(abstract).dy),
    );
    expect(find.textContaining('其他题名'), findsNothing);
    final labelStyle = tester.widget<Text>(find.text('ISBN')).style;
    expect(labelStyle?.fontSize, 11);
    expect(tester.widget<Text>(abstract).style, labelStyle);
    expect(find.text('北京:测试出版社,2021'), findsOneWidget);
    final infoTop = tester.getTopLeft(find.byType(LibraryBookInfoCard)).dy;
    final holdingsTop = tester.getTopLeft(find.text('馆藏位置')).dy;
    expect(infoTop, lessThan(holdingsTop));
    expect(find.text('测试总馆 · 三楼北'), findsOneWidget);
    final firstHolding = tester.getTopLeft(find.text('测试总馆 · 三楼北')).dy;
    final secondHolding = tester.getTopLeft(find.text('测试总馆 · 二楼南')).dy;
    expect(secondHolding - firstHolding, lessThan(64));
    expect(find.text('书架 A12'), findsOneWidget);
    expect(find.text('可借'), findsOneWidget);
    expect(find.text('ISBN'), findsOneWidget);
    expect(find.text('¥ 89.00'), findsOneWidget);

    final copied = find.text('ISBN 已复制');
    for (var index = 0; index < 4; index++) {
      await tester.tap(copy);
      await tester.pump(const Duration(milliseconds: 500));
      expect(copied, findsOneWidget);
    }
    expect(copiedIsbns, List.filled(4, {'text': '978-7-03-022595-5'}));
    expect(
      tester.getTopLeft(copied).dy,
      closeTo(tester.getBottomLeft(find.byType(AppBar)).dy + 20, 2),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(copied, findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(copied, findsNothing);
    expect(paths, hasLength(4));
    await tester.tap(find.text('测试馆藏'));
    await tester.pumpAndSettle();
    expect(copied, findsNothing);
    await tester.pump(const Duration(seconds: 8));
    expect(copied, findsNothing);
    await tester.tap(copy);
    await tester.pump();
    expect(copied, findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(copied, findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.text('我的借阅'));
    await tester.pumpAndSettle();
    expect(find.text('前往门户绑定'), findsOneWidget);
    expect(paths, hasLength(7));
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏大字下 ISBN 留在格内，复制原始号码且不带定价', (tester) async {
    tester.view.physicalSize = const Size(300, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final copiedIsbns = <String>[];

    const firstIsbn = '978-7-03-083819-3';
    const secondIsbn = '9787030225955';
    final book = LibraryBookInfo.fromJson({
      'map': {
        'baseInfo': {
          'map': {
            'title': '测试书目',
            'author': '甲作者、乙作者编著',
            'isbn': [firstIsbn, secondIsbn],
          },
        },
        'detailInfo': {
          'map': {
            '中图法分类号': 'TP301.6',
            'ISBN及定价': '$firstIsbn 精装/CNY78.00',
            '载体形态项': '318页',
            '提要文摘附注': '本书由两名作者编著。',
          },
        },
      },
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: appDarkTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(1.5)),
          child: child!,
        ),
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              LibraryBookInfoCard(
                book: book,
                cover: _fakeCover,
                onCopyIsbn: copiedIsbns.add,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    const isbnText = '$firstIsbn\n$secondIsbn';
    final paragraph = tester.renderObject<RenderParagraph>(find.text(isbnText));
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: isbnText.length),
    );
    expect(boxes.length, greaterThan(2));
    expect(
      boxes.map((box) => box.right),
      everyElement(lessThanOrEqualTo(paragraph.size.width + 0.1)),
    );
    expect(find.text('精装'), findsOneWidget);
    expect(find.text('甲作者、乙作者'), findsOneWidget);
    expect(find.textContaining('编著'), findsNothing);

    final copy = find.byTooltip('复制 ISBN');
    expect(
      tester.widget<IconButton>(find.byType(IconButton).last).iconSize,
      14,
    );
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(copiedIsbns.single, isbnText);
    expect(tester.takeException(), isNull);
  });

  testWidgets('我的借阅在窄屏深色模式下保留紧凑卡片和完整借阅信息', (tester) async {
    tester.view.physicalSize = const Size(350, 690);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final loans = Completer<LibraryResultPage<LibraryLoan>>();
    await tester.pumpWidget(
      MaterialApp(
        theme: appDarkTheme(),
        home: LibraryPage(
          api: _LibraryApi(catalogue: dio, loanPage: loans.future),
        ),
      ),
    );
    await tester.tap(find.text('我的借阅'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    loans.complete(
      LibraryResultPage(
        items: [
          LibraryLoan.fromJson({
            'bibId': 'mock-book',
            'bibAttrs': {'title': '测试借阅书目', 'author': '测试作者'},
            'loanDate': '2026-10-20',
            'dueDate': '2026-11-20',
            'loanStatus': 'soon',
            'location': '测试总馆三楼',
          }),
        ],
        total: 1,
      ),
    );
    await tester.pumpAndSettle();
    final bookTile = find.widgetWithText(ListTile, '测试借阅书目');
    expect(tester.widget<ListTile>(bookTile).dense, isTrue);
    expect(tester.getSize(bookTile).height, lessThan(100));
    for (final text in [
      '测试作者',
      '测试总馆三楼',
      '借出 2026-10-20',
      '应还 2026-11-20',
      '即将到期',
    ]) {
      expect(find.text(text), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });
}
