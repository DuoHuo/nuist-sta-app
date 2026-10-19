import '../../core/config/campus_config.dart';

/// 用户可以订阅的公告主题。
enum BulletinTopic {
  academicCompetition,
  innovationEntrepreneurship,
  sports,
  arts,
  clubs,
  academicTalks,
  scholarships,
  courses,
  exams,
  employment,
  exchange,
  dormitory,
  campusServices,
  importantNotices,
}

/// 主题对应的中文名称和持久化标识。
extension BulletinTopicLabel on BulletinTopic {
  /// 主题的界面显示名称。
  String get label => switch (this) {
    BulletinTopic.academicCompetition => '学科竞赛',
    BulletinTopic.innovationEntrepreneurship => '创新创业',
    BulletinTopic.sports => '体育活动',
    BulletinTopic.arts => '文艺活动',
    BulletinTopic.clubs => '社团活动',
    BulletinTopic.academicTalks => '学术讲座',
    BulletinTopic.scholarships => '奖学金与助学金',
    BulletinTopic.courses => '课程与选课',
    BulletinTopic.exams => '考试与测评',
    BulletinTopic.employment => '就业与实习',
    BulletinTopic.exchange => '交换与国际交流',
    BulletinTopic.dormitory => '宿舍与后勤',
    BulletinTopic.campusServices => '校园服务',
    BulletinTopic.importantNotices => '重要通知',
  };

  /// 稳定的本地存储标识。
  String get id => name;

  /// 根据本地存储标识解析主题。
  static BulletinTopic? fromId(String id) {
    for (final topic in BulletinTopic.values) {
      if (topic.id == id) return topic;
    }
    return null;
  }
}

/// 学校公告栏提供的官方分类。
class BulletinCategory {
  /// 创建一个公告分类。
  const BulletinCategory({required this.name, required this.path});

  final String name;
  final String path;

  /// 分类页对应的官网地址。
  Uri get uri => Uri.parse('https://${CampusHosts.bulletin}/$path');

  /// 公告栏支持的全部官方分类。
  static const all = [
    BulletinCategory(name: '全部公告', path: ''),
    BulletinCategory(name: '文件公告', path: 'wjgg.htm'),
    BulletinCategory(name: '学术报告', path: 'xsbg.htm'),
    BulletinCategory(name: '招标信息', path: 'zbxx.htm'),
    BulletinCategory(name: '会议通知', path: 'hytz2.htm'),
    BulletinCategory(name: '党政事务', path: 'dzsw.htm'),
    BulletinCategory(name: '组织人事', path: 'zzrs.htm'),
    BulletinCategory(name: '科研信息', path: 'kyxx.htm'),
    BulletinCategory(name: '招生就业', path: 'zsjy.htm'),
    BulletinCategory(name: '教学考试', path: 'jxks.htm'),
    BulletinCategory(name: '创新创业', path: 'cxcy.htm'),
    BulletinCategory(name: '学术研讨', path: 'xsyt.htm'),
    BulletinCategory(name: '专题讲座', path: 'ztjz.htm'),
    BulletinCategory(name: '校园活动', path: 'xyhd.htm'),
    BulletinCategory(name: '学院动态', path: 'xydt.htm'),
    BulletinCategory(name: '其他', path: 'qt.htm'),
  ];
}

/// 一条公告及端侧生成的主题标签。
class Bulletin {
  /// 创建一条公告记录。
  const Bulletin({
    required this.id,
    required this.title,
    required this.url,
    required this.officialCategory,
    required this.publisher,
    required this.publishedAt,
    this.topicScores = const {},
    this.actions = const [],
    this.taggerVersion = 0,
  });

  final String id;
  final String title;
  final String url;
  final String officialCategory;
  final String publisher;
  final String publishedAt;
  final Map<String, int> topicScores;
  final List<String> actions;
  final int taggerVersion;

  List<BulletinTopic> get topics => [
    for (final entry in topicScores.entries)
      if (entry.value >= 2) ?BulletinTopicLabel.fromId(entry.key),
  ];

  /// 根据新的主题分数或行为标签创建副本。
  Bulletin copyWith({
    Map<String, int>? topicScores,
    List<String>? actions,
    int? taggerVersion,
  }) => Bulletin(
    id: id,
    title: title,
    url: url,
    officialCategory: officialCategory,
    publisher: publisher,
    publishedAt: publishedAt,
    topicScores: topicScores ?? this.topicScores,
    actions: actions ?? this.actions,
    taggerVersion: taggerVersion ?? this.taggerVersion,
  );

  /// 从本地 JSON 记录恢复公告。
  factory Bulletin.fromJson(Map<String, dynamic> json) {
    final scores = json['topicScores'];
    final topics = json['topics'];
    final parsedScores = <String, int>{};
    if (scores is Map) {
      for (final entry in scores.entries) {
        if (entry.value is num) {
          parsedScores[entry.key.toString()] = (entry.value as num).toInt();
        }
      }
    } else if (topics is List) {
      for (final id in topics.whereType<String>()) {
        parsedScores[id] = 4;
      }
    }
    return Bulletin(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
      officialCategory: (json['officialCategory'] ?? '').toString(),
      publisher: (json['publisher'] ?? '').toString(),
      publishedAt: (json['publishedAt'] ?? '').toString(),
      topicScores: parsedScores,
      actions: (json['actions'] as List?)?.whereType<String>().toList() ?? [],
      taggerVersion: (json['taggerVersion'] as num?)?.toInt() ?? 0,
    );
  }

  /// 将公告转换为本地 JSON 记录。
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'url': url,
    'officialCategory': officialCategory,
    'publisher': publisher,
    'publishedAt': publishedAt,
    'topicScores': topicScores,
    'actions': actions,
    'taggerVersion': taggerVersion,
  };
}

/// 公告正文中可渲染的内容块类型。
enum BulletinDetailBlockKind {
  heading,
  paragraph,
  bulletList,
  numberedList,
  quote,
  image,
  table,
}

/// 公告正文中的一个排版块。
class BulletinDetailBlock {
  /// 创建一个正文排版块。
  const BulletinDetailBlock({
    required this.kind,
    this.text = '',
    this.items = const [],
    this.url,
    this.altText = '',
    this.level = 0,
    this.centered = false,
  });

  final BulletinDetailBlockKind kind;
  final String text;
  final List<String> items;
  final String? url;
  final String altText;
  final int level;
  final bool centered;
}

/// 公告正文中的附件下载项。
class BulletinAttachment {
  /// 创建一个附件下载项。
  const BulletinAttachment({required this.name, required this.url});

  final String name;
  final String url;
}

/// 从公告 HTML 页面提取出的原生阅读内容。
class BulletinDetailDocument {
  /// 创建一份公告正文文档。
  const BulletinDetailDocument({
    required this.blocks,
    required this.attachments,
  });

  final List<BulletinDetailBlock> blocks;
  final List<BulletinAttachment> attachments;

  /// 判断文档是否没有可展示内容。
  bool get isEmpty => blocks.isEmpty && attachments.isEmpty;
}

/// 某个公告列表页及其分页信息。
class BulletinListPage {
  /// 创建一页公告列表。
  const BulletinListPage({
    required this.items,
    required this.pageNumber,
    this.nextUrl,
    this.totalCount,
  });

  final List<Bulletin> items;
  final int pageNumber;
  final String? nextUrl;
  final int? totalCount;

  /// 从本地 JSON 记录恢复公告列表页。
  factory BulletinListPage.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final rawCount = json['totalCount'];
    return BulletinListPage(
      items: [
        if (rawItems is List)
          for (final item in rawItems)
            if (item is Map<String, dynamic>) Bulletin.fromJson(item),
      ],
      pageNumber: (json['pageNumber'] as num?)?.toInt() ?? 1,
      nextUrl: json['nextUrl']?.toString(),
      totalCount: rawCount is num ? rawCount.toInt() : null,
    );
  }

  /// 将公告列表页转换为本地 JSON 记录。
  Map<String, dynamic> toJson() => {
    'items': [for (final item in items) item.toJson()],
    'pageNumber': pageNumber,
    'nextUrl': nextUrl,
    'totalCount': totalCount,
  };
}

/// 用户的公告订阅开关与主题选择。
class BulletinSubscription {
  /// 创建订阅设置；默认关闭且不选择主题。
  const BulletinSubscription({this.enabled = false, this.topics = const {}});

  final bool enabled;
  final Set<BulletinTopic> topics;

  /// 判断公告是否符合已开启的订阅设置。
  bool matches(Bulletin bulletin) =>
      enabled && bulletin.topics.any(topics.contains);

  /// 从本地 JSON 记录恢复订阅设置。
  factory BulletinSubscription.fromJson(Map<String, dynamic>? json) {
    final rawTopics = json?['topics'];
    return BulletinSubscription(
      enabled: json?['enabled'] == true,
      topics: {
        if (rawTopics is List)
          for (final id in rawTopics.whereType<String>())
            ?BulletinTopicLabel.fromId(id),
      },
    );
  }

  /// 将订阅设置转换为本地 JSON 记录。
  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'topics': [for (final topic in topics) topic.id],
  };
}

/// 公告模块需要持久化的缓存、订阅和首页动态。
class BulletinLocalData {
  /// 创建一份公告模块的本地数据快照。
  const BulletinLocalData({
    this.subscription = const BulletinSubscription(),
    this.pages = const {},
    this.feed = const [],
    this.knownIds = const {},
    this.baselineReady = false,
  });

  final BulletinSubscription subscription;
  final Map<String, BulletinListPage> pages;
  final List<Bulletin> feed;
  final Set<String> knownIds;
  final bool baselineReady;

  /// 从本地 JSON 记录恢复公告模块数据。
  factory BulletinLocalData.fromJson(Map<String, dynamic>? json) {
    final rawPages = json?['pages'];
    final pages = <String, BulletinListPage>{};
    if (rawPages is Map) {
      for (final entry in rawPages.entries) {
        if (entry.value is Map<String, dynamic>) {
          pages[entry.key.toString()] = BulletinListPage.fromJson(
            entry.value as Map<String, dynamic>,
          );
        }
      }
    }
    final rawFeed = json?['feed'];
    final rawKnownIds = json?['knownIds'];
    final rawSubscription = json?['subscription'];
    return BulletinLocalData(
      subscription: BulletinSubscription.fromJson(
        rawSubscription is Map<String, dynamic> ? rawSubscription : null,
      ),
      pages: pages,
      feed: [
        if (rawFeed is List)
          for (final item in rawFeed)
            if (item is Map<String, dynamic>) Bulletin.fromJson(item),
      ],
      knownIds: {if (rawKnownIds is List) ...rawKnownIds.whereType<String>()},
      baselineReady: json?['baselineReady'] == true,
    );
  }

  /// 将公告模块数据转换为本地 JSON 记录。
  Map<String, dynamic> toJson() => {
    'subscription': subscription.toJson(),
    'pages': {
      for (final entry in pages.entries) entry.key: entry.value.toJson(),
    },
    'feed': [for (final item in feed) item.toJson()],
    'knownIds': knownIds.toList(),
    'baselineReady': baselineReady,
  };
}
