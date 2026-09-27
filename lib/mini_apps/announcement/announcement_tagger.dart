import 'announcement_models.dart';

/// 当前内置主题规则的版本号。
const announcementTaggerVersion = 1;

class _TopicRule {
  const _TopicRule({
    required this.topic,
    this.strongTitleTerms = const [],
    this.titleTerms = const [],
    this.officialCategories = const [],
    this.exclusions = const [],
  });

  final AnnouncementTopic topic;
  final List<String> strongTitleTerms;
  final List<String> titleTerms;
  final List<String> officialCategories;
  final List<String> exclusions;
}

const _rules = [
  _TopicRule(
    topic: AnnouncementTopic.academicCompetition,
    strongTitleTerms: ['学科竞赛', '数学建模', '程序设计', '英语竞赛', '技能竞赛'],
    titleTerms: ['竞赛', '挑战赛', '大赛'],
    exclusions: ['篮球', '排球', '足球', '羽毛球', '乒乓球', '运动会'],
  ),
  _TopicRule(
    topic: AnnouncementTopic.innovationEntrepreneurship,
    strongTitleTerms: ['创新创业', '创新训练', '创业计划', '创新年会', '商业精英', '挑战杯'],
    titleTerms: ['创业', '创新项目'],
    officialCategories: ['创新创业'],
  ),
  _TopicRule(
    topic: AnnouncementTopic.sports,
    strongTitleTerms: ['篮球', '排球', '足球', '羽毛球', '乒乓球', '运动会', '体育比赛', '体育竞赛'],
    titleTerms: ['体育活动', '健身'],
  ),
  _TopicRule(
    topic: AnnouncementTopic.arts,
    strongTitleTerms: ['文艺活动', '迎新晚会', '毕业晚会', '音乐会', '艺术节'],
    titleTerms: ['晚会', '演出', '书画', '摄影展', '文艺'],
  ),
  _TopicRule(
    topic: AnnouncementTopic.clubs,
    strongTitleTerms: ['社团招新', '学生社团', '社团活动', '社团培训'],
    titleTerms: ['社团'],
  ),
  _TopicRule(
    topic: AnnouncementTopic.academicTalks,
    strongTitleTerms: ['学术报告', '专题讲座', '学术论坛', '学术沙龙', '研讨会'],
    titleTerms: ['讲座', '报告会', '论坛'],
    officialCategories: ['学术报告', '学术研讨', '专题讲座'],
  ),
  _TopicRule(
    topic: AnnouncementTopic.scholarships,
    strongTitleTerms: ['奖学金', '助学金', '困难认定', '国家资助', '勤工助学'],
    titleTerms: ['资助', '奖助', '评奖评优'],
  ),
  _TopicRule(
    topic: AnnouncementTopic.courses,
    strongTitleTerms: ['选课通知', '课程安排', '培养方案', '课程调整'],
    titleTerms: ['选课', '课程', '教学安排', '教学计划'],
  ),
  _TopicRule(
    topic: AnnouncementTopic.exams,
    strongTitleTerms: ['四六级', '普通话测试', '等级考试', '考试安排', '考试报名'],
    titleTerms: ['考试', '考务', '测评', '测试'],
  ),
  _TopicRule(
    topic: AnnouncementTopic.employment,
    strongTitleTerms: ['校园招聘', '招聘会', '企业宣讲', '就业指导', '实习岗位'],
    titleTerms: ['招聘', '就业', '实习', '职业规划'],
  ),
  _TopicRule(
    topic: AnnouncementTopic.exchange,
    strongTitleTerms: ['交换生', '国际交流', '海外学习', '出国交流'],
    titleTerms: ['留学', '国际项目', '海外项目'],
  ),
  _TopicRule(
    topic: AnnouncementTopic.dormitory,
    strongTitleTerms: ['宿舍', '公寓', '寝室', '宿舍用电', '后勤维修'],
    titleTerms: ['食堂', '维修', '后勤', '水电'],
  ),
  _TopicRule(
    topic: AnnouncementTopic.campusServices,
    strongTitleTerms: ['校园卡', '校园网', '图书馆', '班车', '道路施工'],
    titleTerms: ['交通', '开放时间', '服务调整', '场馆开放', '一卡通'],
  ),
  _TopicRule(
    topic: AnnouncementTopic.importantNotices,
    strongTitleTerms: [
      '放假安排',
      '校历调整',
      '紧急通知',
      '校园安全',
      '安全提醒',
      '停水',
      '停电',
      '防台风',
      '防汛',
      '防诈骗',
    ],
    titleTerms: ['全校通知', '应急通知'],
  ),
];

/// 使用标题和官网分类为公告生成主题及行为标签。
Announcement tagAnnouncement(Announcement announcement) {
  final title = _normalize(announcement.title);
  final category = _normalize(announcement.officialCategory);
  final publisher = _normalize(announcement.publisher);
  final scores = <String, int>{};

  for (final rule in _rules) {
    var score = 0;
    if (rule.strongTitleTerms.any(title.contains)) score += 5;
    if (rule.titleTerms.any(title.contains)) score += 2;
    if (rule.officialCategories.any((value) => category == value)) score += 5;
    if (rule.topic == AnnouncementTopic.academicCompetition &&
        rule.exclusions.any(title.contains)) {
      score = 0;
    }
    if (rule.topic == AnnouncementTopic.sports &&
        publisher.contains('体育') &&
        title.contains('比赛')) {
      score += 1;
    }
    if (score > 0) scores[rule.topic.id] = score;
  }

  return announcement.copyWith(
    topicScores: scores,
    actions: _actions(title),
    taggerVersion: announcementTaggerVersion,
  );
}

String _normalize(String value) => value
    .replaceAll(RegExp(r'\s+'), '')
    .replaceAll('【', '[')
    .replaceAll('】', ']')
    .toLowerCase();

List<String> _actions(String title) {
  final actions = <String>{};
  if ((title.contains('报名') || title.contains('参赛')) &&
      !title.contains('无需报名')) {
    actions.add('报名');
  }
  if (title.contains('申报') || title.contains('申请')) actions.add('申报');
  if (title.contains('考试') || title.contains('测评')) actions.add('考试');
  if (title.contains('公示') || title.contains('获奖名单')) {
    actions.add('结果公示');
  }
  if (['讲座', '报告', '论坛', '沙龙', '研讨会'].any(title.contains)) {
    actions.add('学术活动');
  }
  if (['停水', '停电', '施工', '服务调整', '维修'].any(title.contains)) {
    actions.add('服务变更');
  }
  return actions.toList(growable: false);
}
