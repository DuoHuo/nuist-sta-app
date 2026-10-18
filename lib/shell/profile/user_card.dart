import 'package:flutter/material.dart';

import '../../core/colors.dart';

/// 「我的」页顶部的统一门户绑定状态卡片。不展示姓名，学号只展示脱敏后的。
class PortalStatusCard extends StatelessWidget {
  const PortalStatusCard({
    super.key,
    required this.bound,
    required this.maskedStudentId,
    required this.revoked,
    required this.onTap,
  });

  /// null = 还没读到安全存储的结果。
  final bool? bound;

  /// 已脱敏的学号；已绑定但解不出学号时为 null。
  final String? maskedStudentId;

  /// 凭据被门户拒绝过。
  final bool revoked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (title, subtitle) = switch (bound) {
      null => ('统一门户', ''),
      true => (
        '已绑定统一门户',
        '${maskedStudentId ?? '学号未知'}${revoked ? ' · 已失效' : ''}',
      ),
      false => ('未绑定统一门户', '点击绑定'),
    };
    // Material 画底色并按圆角裁剪，水波纹才看得见且不溢出圆角。
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 92,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: AppColors.accent,
                child: Icon(
                  bound == true ? Icons.verified_user : Icons.person,
                  color: Colors.white,
                  size: 30,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.titleText,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.hint,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Color(0xFFC9CDD4)),
            ],
          ),
        ),
      ),
    );
  }
}
