import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/announcement/announcement_detail_parser.dart';
import 'package:nuist_sta_app/mini_apps/announcement/announcement_models.dart';

void main() {
  test('announcement detail parses native blocks and attachment', () {
    final document = parseAnnouncementDetail(
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
      currentUri: Uri.parse('https://bulletin.nuist.edu.cn/info/1/123.htm'),
    );

    expect(document, isNotNull);
    expect(
      document!.blocks.map((block) => block.kind),
      containsAll([
        AnnouncementDetailBlockKind.heading,
        AnnouncementDetailBlockKind.paragraph,
        AnnouncementDetailBlockKind.bulletList,
      ]),
    );
    expect(document.blocks.first.text, 'Activity plan');
    expect(document.attachments.single.name, 'Attachment: notice.pdf');
    expect(
      document.attachments.single.url,
      'https://bulletin.nuist.edu.cn/files/notice.pdf',
    );
  });

  test('restricted page returns null for WebView fallback', () {
    final document = parseAnnouncementDetail(
      'ONLY_ON_CAMPUS_ADDRESS',
      currentUri: Uri.parse('https://bulletin.nuist.edu.cn/info/1/123.htm'),
    );

    expect(document, isNull);
  });

  test('page without article body returns null', () {
    final document = parseAnnouncementDetail(
      '<html><body><nav>Home</nav><footer>School</footer></body></html>',
      currentUri: Uri.parse('https://bulletin.nuist.edu.cn/info/1/123.htm'),
    );

    expect(document, isNull);
  });
}
