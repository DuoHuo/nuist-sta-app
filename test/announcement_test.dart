import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/announcement/announcement_api.dart';
import 'package:nuist_sta_app/mini_apps/announcement/announcement_models.dart';
import 'package:nuist_sta_app/mini_apps/announcement/announcement_tagger.dart';

void main() {
  test('订阅主题共 14 个，且默认关闭', () {
    expect(AnnouncementTopic.values, hasLength(14));
    const subscription = AnnouncementSubscription();
    expect(subscription.enabled, isFalse);
    expect(subscription.topics, isEmpty);
  });

  test('公告按标题和官网分类生成主题与行为标签', () {
    final announcement = tagAnnouncement(
      const Announcement(
        id: '12345',
        title: '关于开展数学建模竞赛报名的通知',
        url: 'https://bulletin.nuist.edu.cn/info/1/12345.htm',
        officialCategory: '创新创业',
        publisher: '教务处',
        publishedAt: '2026-09-27',
      ),
    );

    expect(
      announcement.topics,
      containsAll([
        AnnouncementTopic.academicCompetition,
        AnnouncementTopic.innovationEntrepreneurship,
      ]),
    );
    expect(announcement.actions, contains('报名'));
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

    final page = parseAnnouncementPage(
      html,
      currentUri: Uri.parse('https://bulletin.nuist.edu.cn/'),
      pageNumber: 1,
    );

    expect(page.items, hasLength(1));
    expect(page.items.single.id, '12345');
    expect(page.items.single.officialCategory, '学术报告');
    expect(page.items.single.publisher, '科研处');
    expect(page.items.single.topics, contains(AnnouncementTopic.academicTalks));
    expect(page.totalCount, 100);
    expect(page.nextUrl, 'https://bulletin.nuist.edu.cn/index_2.htm');
  });
}
