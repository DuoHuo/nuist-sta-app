import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/colors.dart';
import '../../core/time_format.dart';
import 'student_info_controller.dart';
import 'student_info_models.dart';

/// 学习页顶部的「本学期」卡：当前学期、周次与学期进度。回答的是「现在是
/// 什么时候的数据」，所以放在整页最上面。
///
/// 接口同时给了姓名 / 学号 / 学院·班级，但用户不需要在自己的学习页上反复
/// 看自己是谁，这一行默认不显示（见 [showIdentity]）；身份信息改在
/// 「绑定统一门户」状态页展示，那里才是「绑的是不是我」的问题所在。
///
/// 未绑定门户 / 从未拉到数据时退化成带标题的一行提示，和其他卡片一致。
class StudentInfoCard extends StatefulWidget {
  const StudentInfoCard({super.key});

  /// 是否把卡头换成「头像 + 姓名 + 学号 · 学院 · 班级」。数据与组件都留着，
  /// 需要时打开即可。
  static const showIdentity = false;

  @override
  State<StudentInfoCard> createState() => _StudentInfoCardState();
}

class _StudentInfoCardState extends State<StudentInfoCard> {
  final _controller = StudentInfoController.instance;

  @override
  void initState() {
    super.initState();
    _controller.ensureStarted();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final c = _controller;
        final info = c.info;
        final error = c.error;
        final identity = StudentInfoCard.showIdentity && info != null;

        final Widget body;
        if (!c.portalBound) {
          body = _Placeholder(
            text: '请先绑定统一门户',
            action: '去绑定',
            onTap: () => context.push('/portal-bind'),
          );
        } else if (info == null) {
          body = _Placeholder(
            text: c.loading ? '正在获取校历…' : (error ?? '暂无数据'),
            action: c.loading ? null : '重试',
            onTap: c.refresh,
            isError: !c.loading && error != null,
          );
        } else {
          body = _SemesterSection(semester: info.semester, divided: identity);
        }

        return Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (StudentInfoCard.showIdentity && info != null)
                    Expanded(child: _Identity(user: info.user))
                  else ...[
                    const Icon(
                      Icons.calendar_today_outlined,
                      size: 18,
                      color: AppColors.accent,
                    ),
                    const SizedBox(width: 4),
                    const Text(
                      '本学期',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.titleText,
                      ),
                    ),
                    const Spacer(),
                  ],
                  if (c.portalBound) ...[
                    if (error != null && info != null)
                      Text(
                        '更新失败',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    _RefreshButton(loading: c.loading, onPressed: c.refresh),
                  ] else
                    const SizedBox(height: 32),
                ],
              ),
              Padding(padding: const EdgeInsets.only(right: 8), child: body),
            ],
          ),
        );
      },
    );
  }
}

/// 头像首字 + 「姓名  学号」+ 「学院 · 班级」。学号跟在姓名后面而不是和班级
/// 挤一行：学号 12 位加上学院、班级名，一行放不下。
class _Identity extends StatelessWidget {
  const _Identity({required this.user});

  final PortalUser user;

  @override
  Widget build(BuildContext context) {
    final org = user.orgLine;
    return Row(
      children: [
        CircleAvatar(
          radius: 20,
          backgroundColor: AppColors.accent,
          child: Text(
            user.initial,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Flexible(
                    child: Text(
                      user.name.isEmpty ? '--' : user.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.titleText,
                      ),
                    ),
                  ),
                  if (user.studentId.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(
                      user.studentId,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.labelText,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 3),
              Text(
                org.isEmpty ? '--' : org,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.labelText,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 学期名 + 周次标签 + 进度条 + 起止日期；没有校历时只给一行提示。
///
/// [divided] 为 true 时先画一条分割线，用于上面是身份行的布局。
class _SemesterSection extends StatelessWidget {
  const _SemesterSection({required this.semester, required this.divided});

  final SemesterInfo? semester;
  final bool divided;

  @override
  Widget build(BuildContext context) {
    final s = semester;
    final now = DateTime.now();

    final String phase;
    final Color phaseColor;
    if (s == null) {
      phase = '';
      phaseColor = AppColors.hint;
    } else if (s.isBeforeStart(now)) {
      phase = '未开学';
      phaseColor = AppColors.hint;
    } else if (s.isEnded(now)) {
      phase = '假期中';
      phaseColor = AppColors.hint;
    } else {
      phase = '第 ${s.weekOf(now)} 周';
      phaseColor = AppColors.accent;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (divided) ...[
          const SizedBox(height: 12),
          const Divider(height: 1, color: AppColors.rowDivider),
        ],
        const SizedBox(height: 10),
        if (s == null)
          const Text(
            '暂无当前学期的校历信息',
            style: TextStyle(fontSize: 12, color: AppColors.hint),
          )
        else ...[
          Row(
            children: [
              Text(
                s.label,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.titleText,
                ),
              ),
              const SizedBox(width: 8),
              _Chip(text: phase, color: phaseColor),
              const Spacer(),
              if (s.maxWeeks > 0)
                Text(
                  '共 ${s.maxWeeks} 周',
                  style: const TextStyle(fontSize: 11, color: AppColors.hint),
                ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: s.isEnded(now) ? 1 : s.progressAt(now),
              minHeight: 5,
              backgroundColor: AppColors.rowDivider,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              Text(
                '${formatMonthDay(s.start)} 开学',
                style: const TextStyle(fontSize: 10, color: AppColors.hint),
              ),
              const Spacer(),
              Text(
                '${formatMonthDay(s.end)} 结束',
                style: const TextStyle(fontSize: 10, color: AppColors.hint),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.text,
    required this.onTap,
    this.action,
    this.isError = false,
  });

  final String text;
  final String? action;
  final VoidCallback onTap;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 14,
                color: isError
                    ? Theme.of(context).colorScheme.error
                    : AppColors.hint,
              ),
            ),
          ),
          if (action != null)
            TextButton(
              onPressed: onTap,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(action!),
            ),
        ],
      ),
    );
  }
}

/// 刷新图标按钮，加载中原位换成小转圈，占位尺寸不变。
class _RefreshButton extends StatelessWidget {
  const _RefreshButton({required this.loading, required this.onPressed});

  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: loading
          ? const Center(
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : IconButton(
              padding: EdgeInsets.zero,
              iconSize: 18,
              color: AppColors.accent,
              icon: const Icon(Icons.refresh),
              onPressed: onPressed,
            ),
    );
  }
}
