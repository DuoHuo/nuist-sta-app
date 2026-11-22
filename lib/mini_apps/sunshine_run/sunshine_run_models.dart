/// 阳光跑的离线计算模型；晨跑次数始终包含在总次数中。
library;

/// 与前端及 JSON 保持一致的安全整数上界。
const int kSunshineRunMaxCount = 9007199254740991;

/// 自定义活动最多保留的项目数。
const int kSunshineRunMaxCustomActivities = 50;

/// 自定义活动名称最多包含的 Unicode 字符数。
const int kSunshineRunMaxLabelLength = 30;

/// 比赛减免；半免仅减半总次数要求，全免无需跑步。
enum SunshineRunExemption { none, half, full }

/// 总次数完成度与成绩判定分别计算。
enum SunshineRunStatus { incomplete, passed, full, exempt }

/// 一种固定活动的单场折算规则。
class SunshineRunActivity {
  const SunshineRunActivity({
    required this.id,
    required this.label,
    required this.total,
    required this.morning,
  });

  /// 稳定的活动标识。
  final String id;

  /// 活动名称。
  final String label;

  /// 单场计入的总次数。
  final int total;

  /// 单场总次数中属于晨跑的次数。
  final int morning;
}

/// 固定活动按参加场次记录，规则不随用户输入改变。
const List<SunshineRunActivity> kSunshineRunActivities = [
  SunshineRunActivity(id: 'regular', label: '普通跑', total: 1, morning: 0),
  SunshineRunActivity(id: 'morning', label: '普通晨跑', total: 1, morning: 1),
  SunshineRunActivity(id: 'fluorescent', label: '3km荧光跑', total: 2, morning: 2),
  SunshineRunActivity(id: 'monday', label: '周一晨跑活动（2km）', total: 2, morning: 2),
];

const Map<String, int> _emptyActivities = {
  'regular': 0,
  'morning': 0,
  'fluorescent': 0,
  'monday': 0,
};

/// 校验十进制整数输入；空白、小数、负数和科学计数均不接受。
///
/// 文本两端空格会去除；数值输入必须直接是整数，不能把浮点数截断。
int parseSunshineRunCount(
  Object? raw, {
  bool positive = false,
  String label = '次数',
}) {
  final message = positive ? '$label请填写大于 0 的整数' : '$label请填写非负整数';
  int value;
  if (raw is int) {
    value = raw;
  } else if (raw is String) {
    final text = raw.trim();
    if (!RegExp(r'^[0-9]+$').hasMatch(text)) {
      throw FormatException(message);
    }
    // 先比较十进制文本，避免 int.parse 在不同平台先溢出或丢失精度。
    final digits = text.replaceFirst(RegExp(r'^0+'), '');
    final normalized = digits.isEmpty ? '0' : digits;
    final maximum = kSunshineRunMaxCount.toString();
    if (normalized.length > maximum.length ||
        (normalized.length == maximum.length &&
            normalized.compareTo(maximum) > 0)) {
      throw FormatException('$label过大，请减少次数');
    }
    value = int.parse(normalized);
  } else {
    throw FormatException(message);
  }
  if (value < 0 || (positive && value == 0)) {
    throw FormatException(message);
  }
  if (value > kSunshineRunMaxCount) {
    throw FormatException('$label过大，请减少次数');
  }
  return value;
}

int _jsonCount(Object? raw, String label, {bool positive = false}) {
  if (raw is! int) throw FormatException('$label记录必须是整数');
  return parseSunshineRunCount(raw, label: label, positive: positive);
}

int _checkGrade(Object? grade) {
  if (grade is! int || (grade != 1 && grade != 2)) {
    throw const FormatException('年级只能选择大一或大二');
  }
  return grade;
}

SunshineRunExemption _exemptionFromJson(Object? value) {
  for (final exemption in SunshineRunExemption.values) {
    if (value == exemption.name) return exemption;
  }
  throw const FormatException('减免设置无效');
}

int _checkedProduct(int count, int weight) {
  if (weight != 0 && count > kSunshineRunMaxCount ~/ weight) {
    throw const FormatException('活动累计过大，请减少场次或单场次数');
  }
  return count * weight;
}

int _checkedAdd(int left, int right) {
  if (right > kSunshineRunMaxCount - left) {
    throw const FormatException('总次数累计过大，请减少已有次数或活动场次');
  }
  return left + right;
}

/// 自定义活动及其参加场次；晨跑折算不能超过单场总次数。
class SunshineRunCustomActivity {
  factory SunshineRunCustomActivity({
    required String id,
    String label = '',
    int total = 1,
    int morning = 0,
    int count = 0,
  }) {
    final cleanId = id.trim();
    if (cleanId.isEmpty) {
      throw const FormatException('自定义活动标识不能为空');
    }
    final name = label.trim();
    final cleanLabel = name.isEmpty ? '其他活动' : name;
    if (cleanLabel.runes.length > kSunshineRunMaxLabelLength) {
      throw const FormatException('自定义活动名称不能超过 30 个字符');
    }
    if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(cleanLabel)) {
      throw const FormatException('自定义活动名称不能包含换行或控制字符');
    }
    parseSunshineRunCount(total, positive: true, label: '每场总次数');
    parseSunshineRunCount(morning, label: '每场晨跑次数');
    parseSunshineRunCount(count, label: '自定义活动场次');
    if (morning > total) {
      throw const FormatException('每场晨跑次数不能超过每场总次数，晨跑已包含在总次数中');
    }
    _checkedProduct(count, total);
    _checkedProduct(count, morning);
    return SunshineRunCustomActivity._(
      id: cleanId,
      label: cleanLabel,
      total: total,
      morning: morning,
      count: count,
    );
  }

  const SunshineRunCustomActivity._({
    required this.id,
    required this.label,
    required this.total,
    required this.morning,
    required this.count,
  });

  /// 稳定标识，由控制器在创建活动时生成。
  final String id;

  /// 用户填写的活动名称。
  final String label;

  /// 单场总次数。
  final int total;

  /// 单场总次数中属于晨跑的次数。
  final int morning;

  /// 实际参加场次。
  final int count;

  /// 返回修改后的活动，保留原标识并重新校验折算结果。
  SunshineRunCustomActivity copyWith({
    String? label,
    int? total,
    int? morning,
    int? count,
  }) => SunshineRunCustomActivity(
    id: id,
    label: label ?? this.label,
    total: total ?? this.total,
    morning: morning ?? this.morning,
    count: count ?? this.count,
  );

  /// 输出严格的整数记录，不共享可修改集合。
  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'total': total,
    'morning': morning,
    'count': count,
  };

  /// 从本机记录恢复活动，拒绝损坏标识及非整数计数。
  factory SunshineRunCustomActivity.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final label = json['label'];
    if (id is! String || (label != null && label is! String)) {
      throw const FormatException('自定义活动名称或标识格式无效');
    }
    return SunshineRunCustomActivity(
      id: id,
      label: label as String? ?? '',
      total: _jsonCount(json['total'], '每场总次数', positive: true),
      morning: _jsonCount(json['morning'], '每场晨跑次数'),
      count: _jsonCount(json['count'], '自定义活动场次'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SunshineRunCustomActivity &&
      id == other.id &&
      label == other.label &&
      total == other.total &&
      morning == other.morning &&
      count == other.count;

  @override
  int get hashCode => Object.hash(id, label, total, morning, count);
}

/// 不可变的计算记录，可直接作为撤销快照保留。
class SunshineRunState {
  factory SunshineRunState({
    int grade = 2,
    SunshineRunExemption exemption = SunshineRunExemption.none,
    int baseTotal = 0,
    int baseMorning = 0,
    Map<String, int> activities = _emptyActivities,
    List<SunshineRunCustomActivity> customActivities = const [],
  }) {
    _checkGrade(grade);
    parseSunshineRunCount(baseTotal, label: '已有总次数');
    parseSunshineRunCount(baseMorning, label: '已有晨跑次数');
    if (baseMorning > baseTotal) {
      throw const FormatException('已有晨跑次数不能超过已有总次数，晨跑已包含在总次数中');
    }
    if (activities.length != kSunshineRunActivities.length ||
        kSunshineRunActivities.any(
          (activity) => !activities.containsKey(activity.id),
        )) {
      throw const FormatException('固定活动记录不完整或包含未知活动');
    }
    final cleanActivities = <String, int>{
      for (final activity in kSunshineRunActivities)
        activity.id: parseSunshineRunCount(
          activities[activity.id],
          label: '${activity.label}场次',
        ),
    };
    if (customActivities.length > kSunshineRunMaxCustomActivities) {
      throw const FormatException('自定义活动数量已达上限（50 项）');
    }
    final cleanCustom = List<SunshineRunCustomActivity>.unmodifiable(
      customActivities,
    );
    final ids = kSunshineRunActivities.map((activity) => activity.id).toSet();
    for (final item in cleanCustom) {
      if (!ids.add(item.id)) {
        throw const FormatException('自定义活动标识重复或与固定活动冲突');
      }
    }
    var total = baseTotal;
    var morning = baseMorning;
    for (final activity in kSunshineRunActivities) {
      final count = cleanActivities[activity.id]!;
      total = _checkedAdd(total, _checkedProduct(count, activity.total));
      morning = _checkedAdd(morning, _checkedProduct(count, activity.morning));
    }
    for (final item in cleanCustom) {
      total = _checkedAdd(total, _checkedProduct(item.count, item.total));
      morning = _checkedAdd(morning, _checkedProduct(item.count, item.morning));
    }
    return SunshineRunState._(
      grade: grade,
      exemption: exemption,
      baseTotal: baseTotal,
      baseMorning: baseMorning,
      activities: Map<String, int>.unmodifiable(cleanActivities),
      customActivities: cleanCustom,
      total: total,
      morning: morning,
    );
  }

  const SunshineRunState._({
    required this.grade,
    required this.exemption,
    required this.baseTotal,
    required this.baseMorning,
    required this.activities,
    required this.customActivities,
    required this._total,
    required this._morning,
  });

  /// 新用户默认大二、无减免且所有次数为零。
  factory SunshineRunState.initial() => SunshineRunState();

  /// 本机记录格式版本。
  static const int formatVersion = 1;

  /// 当前记录的格式版本。
  int get version => formatVersion;

  /// 年级，1 为大一，2 为大二。
  final int grade;

  /// 当前唯一的比赛减免设置。
  final SunshineRunExemption exemption;

  /// 开始使用计算器前已有的总次数。
  final int baseTotal;

  /// 已有总次数中属于晨跑的次数。
  final int baseMorning;

  /// 固定活动的新增场次，只读且始终包含四个固定标识。
  final Map<String, int> activities;

  /// 自定义活动及其新增场次，只读并按录入顺序保留。
  final List<SunshineRunCustomActivity> customActivities;

  final int _total;
  final int _morning;

  /// 返回重新校验的新记录，未给出的字段沿用原值。
  SunshineRunState copyWith({
    int? grade,
    SunshineRunExemption? exemption,
    int? baseTotal,
    int? baseMorning,
    Map<String, int>? activities,
    List<SunshineRunCustomActivity>? customActivities,
  }) => SunshineRunState(
    grade: grade ?? this.grade,
    exemption: exemption ?? this.exemption,
    baseTotal: baseTotal ?? this.baseTotal,
    baseMorning: baseMorning ?? this.baseMorning,
    activities: activities ?? this.activities,
    customActivities: customActivities ?? this.customActivities,
  );

  /// 以绝对场次修改一项固定活动。
  SunshineRunState withActivity(String id, int count) {
    if (!activities.containsKey(id)) {
      throw const FormatException('活动类型无效');
    }
    return copyWith(activities: {...activities, id: count});
  }

  /// 修改已有基数，保留全部新增活动。
  SunshineRunState withBaseline(int total, int morning) =>
      copyWith(baseTotal: total, baseMorning: morning);

  /// 添加自定义活动，校验标识唯一性及累计上界。
  SunshineRunState withCustomAdded(SunshineRunCustomActivity item) =>
      copyWith(customActivities: [...customActivities, item]);

  /// 替换同一标识的自定义活动，保持原来的列表位置。
  SunshineRunState withCustomUpdated(SunshineRunCustomActivity item) {
    if (!customActivities.any((activity) => activity.id == item.id)) {
      throw const FormatException('未找到对应的自定义活动');
    }
    return copyWith(
      customActivities: [
        for (final activity in customActivities)
          if (activity.id == item.id) item else activity,
      ],
    );
  }

  /// 以绝对场次修改自定义活动。
  SunshineRunState withCustomCount(String id, int count) {
    for (final item in customActivities) {
      if (item.id == id) return withCustomUpdated(item.copyWith(count: count));
    }
    throw const FormatException('未找到对应的自定义活动');
  }

  /// 删除自定义活动及其已计入的新增次数。
  SunshineRunState withCustomRemoved(String id) {
    if (!customActivities.any((activity) => activity.id == id)) {
      throw const FormatException('未找到对应的自定义活动');
    }
    return copyWith(
      customActivities: customActivities
          .where((item) => item.id != id)
          .toList(),
    );
  }

  /// 清空新增场次，保留已有基数、年级、减免及自定义活动定义。
  SunshineRunState clearActivities() => copyWith(
    activities: _emptyActivities,
    customActivities: [
      for (final item in customActivities) item.copyWith(count: 0),
    ],
  );

  /// 清空全部跑步记录并恢复无减免，保留当前年级。
  SunshineRunState resetAll() => SunshineRunState(grade: grade);

  /// 计算总次数完成率及成绩状态，晨跑不再额外计入总次数。
  SunshineRunResult calculate() {
    final standardTotal = grade == 1 ? 36 : 48;
    final half = exemption == SunshineRunExemption.half;
    final fullTotal = half ? standardTotal ~/ 2 : standardTotal;
    final passingTotal = grade == 1 ? null : (half ? 12 : 24);
    final requiredMorning = grade == 1 ? 12 : 15;
    final exempt = exemption == SunshineRunExemption.full;
    final full = _total >= fullTotal && _morning >= requiredMorning;
    final passed =
        _morning >= requiredMorning &&
        (passingTotal == null || _total >= passingTotal);
    int remaining(int target, int actual) =>
        exempt || actual >= target ? 0 : target - actual;
    return SunshineRunResult(
      total: _total,
      morning: _morning,
      fullTotal: fullTotal,
      passingTotal: passingTotal,
      requiredMorning: requiredMorning,
      percentage: exempt
          ? 100
          : ((_total / fullTotal).clamp(0.0, 1.0) * 100).round(),
      morningPercentage: exempt
          ? 100
          : ((_morning / requiredMorning).clamp(0.0, 1.0) * 100).round(),
      status: exempt
          ? SunshineRunStatus.exempt
          : full
          ? SunshineRunStatus.full
          : passed
          ? SunshineRunStatus.passed
          : SunshineRunStatus.incomplete,
      remainingFullTotal: remaining(fullTotal, _total),
      remainingPassingTotal: passingTotal == null
          ? 0
          : remaining(passingTotal, _total),
      remainingMorning: remaining(requiredMorning, _morning),
      addedTotal: _total - baseTotal,
      addedMorning: _morning - baseMorning,
    );
  }

  /// 输出本机 JSON，不包含计算目标或可修改的内部集合引用。
  Map<String, dynamic> toJson() => {
    'version': version,
    'grade': grade,
    'exemption': exemption.name,
    'baseTotal': baseTotal,
    'baseMorning': baseMorning,
    'activities': {...activities},
    'customActivities': [for (final item in customActivities) item.toJson()],
  };

  /// 从本机 JSON 恢复；旧记录没有自定义活动时按空列表兼容。
  factory SunshineRunState.fromJson(Map<String, dynamic> json) {
    if (json['version'] is! int || json['version'] != formatVersion) {
      throw const FormatException('阳光跑记录格式或版本无效');
    }
    final activities = json['activities'];
    if (activities is! Map<String, dynamic>) {
      throw const FormatException('固定活动记录格式无效');
    }
    final rawCustom = json.containsKey('customActivities')
        ? json['customActivities']
        : const <dynamic>[];
    if (rawCustom is! List) {
      throw const FormatException('自定义活动记录格式无效');
    }
    return SunshineRunState(
      grade: _checkGrade(json['grade']),
      exemption: _exemptionFromJson(json['exemption']),
      baseTotal: _jsonCount(json['baseTotal'], '已有总次数'),
      baseMorning: _jsonCount(json['baseMorning'], '已有晨跑次数'),
      activities: {
        for (final entry in activities.entries)
          entry.key: _jsonCount(entry.value, '固定活动场次'),
      },
      customActivities: [
        for (final item in rawCustom)
          if (item is Map<String, dynamic>)
            SunshineRunCustomActivity.fromJson(item)
          else
            throw const FormatException('自定义活动项格式无效'),
      ],
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is! SunshineRunState ||
        grade != other.grade ||
        exemption != other.exemption ||
        baseTotal != other.baseTotal ||
        baseMorning != other.baseMorning ||
        customActivities.length != other.customActivities.length) {
      return false;
    }
    for (final activity in kSunshineRunActivities) {
      if (activities[activity.id] != other.activities[activity.id]) {
        return false;
      }
    }
    for (var i = 0; i < customActivities.length; i++) {
      if (customActivities[i] != other.customActivities[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    grade,
    exemption,
    baseTotal,
    baseMorning,
    Object.hashAll(
      kSunshineRunActivities.map((activity) => activities[activity.id]),
    ),
    Object.hashAll(customActivities),
  );
}

/// 一份记录对应的展示结果；百分比封顶而实际次数始终保留。
class SunshineRunResult {
  const SunshineRunResult({
    required this.total,
    required this.morning,
    required this.fullTotal,
    required this.passingTotal,
    required this.requiredMorning,
    required this.percentage,
    required this.morningPercentage,
    required this.status,
    required this.remainingFullTotal,
    required this.remainingPassingTotal,
    required this.remainingMorning,
    required this.addedTotal,
    required this.addedMorning,
  });

  /// 累计总次数，已包含晨跑。
  final int total;

  /// 累计总次数中属于晨跑的次数。
  final int morning;

  /// 当前年级及减免下的满分总次数门槛。
  final int fullTotal;

  /// 达标总次数门槛；大一没有独立门槛，返回 null。
  final int? passingTotal;

  /// 满分和达标均需满足的晨跑次数门槛。
  final int requiredMorning;

  /// 总次数对满分总次数目标的百分比，四舍五入且封顶 100。
  final int percentage;

  /// 晨跑对晨跑目标的百分比，四舍五入且封顶 100。
  final int morningPercentage;

  /// 当前成绩状态。
  final SunshineRunStatus status;

  /// 满分尚缺的总次数，全免时为零。
  final int remainingFullTotal;

  /// 达标尚缺的总次数，大一或全免时为零。
  final int remainingPassingTotal;

  /// 尚缺的晨跑次数，全免时为零。
  final int remainingMorning;

  /// 所有新增活动折算的总次数。
  final int addedTotal;

  /// 新增总次数中属于晨跑的次数。
  final int addedMorning;
}
