import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_detail_parser.dart';
import 'package:nuist_sta_app/mini_apps/bulletin/bulletin_models.dart';

void main() {
  test('bulletin detail parses native blocks and attachment', () {
    final document = parseBulletinDetail(
      '''
      <html><body>
        <div class="wp_articlecontent">
          <h2>Activity plan</h2>
          <p style="text-align:center">Announcement body.</p>
          <ul><li>First item</li><li>Second item</li></ul>
          <p><a href="../../files/notice.pdf">Attachment: notice.pdf</a></p>
        </div>
      </body></html>
      ''',
      currentUri: Uri.parse('https://bulletin.campus.invalid/info/1/123.htm'),
    );

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
  });

  test('restricted page returns null for WebView fallback', () {
    final document = parseBulletinDetail(
      'ONLY_ON_CAMPUS_ADDRESS',
      currentUri: Uri.parse('https://bulletin.campus.invalid/info/1/123.htm'),
    );

    expect(document, isNull);
  });

  test('提取正文外的官网附件列表，正文仍只保留文章内容', () {
    final document = parseBulletinDetail(
      '''
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
      ''',
      currentUri: Uri.parse('https://bulletin.campus.invalid/info/1/123.htm'),
    )!;

    expect(document.attachments.map((item) => item.name), [
      '材料.pdf',
      '申请表.xlsx',
    ]);
    expect(
      document.attachments.first.url,
      'https://bulletin.campus.invalid/system/_content/download.jsp?urltype=news.DownloadAttachUrl&owner=1&wbfileid=11',
    );
    expect(document.blocks.map((block) => block.text), ['请查阅下方材料。']);
  });

  test('识别没有扩展名和附件字样的官网下载接口', () {
    final document = parseBulletinDetail(
      '''
      <article>
        <div class="wp_articlecontent"><p>请查阅材料。</p></div>
        <a href="/system/_content/download.jsp?urltype=news.DownloadAttachUrl&amp;wbfileid=11">申报材料</a>
      </article>
      ''',
      currentUri: Uri.parse('https://bulletin.campus.invalid/info/1/123.htm'),
    )!;

    expect(document.attachments.single.name, '申报材料');
  });

  test('正文和正文外列表中的同一附件只展示一次', () {
    final document = parseBulletinDetail(
      '''
      <form name="_newscontent_fromname">
        <div class="wp_articlecontent">
          <p>请提交材料。</p>
          <p><a href="../../files/form.docx">申请表.docx</a></p>
        </div>
        <ul><li><a href="/files/form.docx">申请表.docx</a></li></ul>
      </form>
      ''',
      currentUri: Uri.parse('https://bulletin.campus.invalid/info/1/123.htm'),
    )!;

    expect(document.attachments, hasLength(1));
    expect(document.attachments.single.name, '申请表.docx');
    expect(document.blocks.map((block) => block.text), ['请提交材料。']);
  });

  test('文章外的导航和侧栏文件不混入公告附件', () {
    final document = parseBulletinDetail(
      '''
      <header><a href="/files/help.pdf">帮助.pdf</a></header>
      <div class="article">
        <div class="wp_articlecontent"><p>公告正文。</p></div>
        <a href="/files/form.pdf">申请表.pdf</a>
        <aside><a href="/files/related.pdf">相关材料.pdf</a></aside>
      </div>
      <div class="sidebar"><a href="/files/other.pdf">其他公告附件.pdf</a></div>
      <footer><a href="/files/manual.pdf">手册.pdf</a></footer>
      ''',
      currentUri: Uri.parse('https://bulletin.campus.invalid/info/1/123.htm'),
    )!;

    expect(document.attachments.single.name, '申请表.pdf');
  });

  test('没有文章容器时仍能读取独立附件区并跳过隐藏内容', () {
    final document = parseBulletinDetail(
      '''
      <body>
        <nav><a href="/help.pdf">帮助.pdf</a></nav>
        <div class="wp_articlecontent"><p>公告正文。</p></div>
        <ul><li><a href="/files/form.pdf">申请表.pdf</a></li></ul>
        <div style="display:none"><a href="/files/hidden.pdf">隐藏.pdf</a></div>
        <footer><a href="/manual.pdf">手册.pdf</a></footer>
      </body>
      ''',
      currentUri: Uri.parse('https://bulletin.campus.invalid/info/1/123.htm'),
    )!;

    expect(document.attachments.single.name, '申请表.pdf');
  });

  test('附件地址无后缀时也识别链接中的文件名', () {
    final document = parseBulletinDetail(
      '''
      <div class="wp_articlecontent">
        <p>请提交材料。</p>
        <p><a href="/files/get?id=11">申请表.DOCX</a></p>
      </div>
      ''',
      currentUri: Uri.parse('https://bulletin.campus.invalid/info/1/123.htm'),
    )!;

    expect(document.attachments.single.name, '申请表.DOCX');
    expect(document.blocks.map((block) => block.text), ['请提交材料。']);
  });

  test('page without article body returns null', () {
    final document = parseBulletinDetail(
      '<html><body><nav>Home</nav><footer>School</footer></body></html>',
      currentUri: Uri.parse('https://bulletin.campus.invalid/info/1/123.htm'),
    );

    expect(document, isNull);
  });
}
