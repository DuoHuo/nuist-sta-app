import 'package:flutter/material.dart';

import '../../../core/colors.dart';
import '../../../core/theme_mode.dart';

/// App 级设置页。目前只有「外观 → 深色模式」：跟随系统 / 浅色 / 深色 三选一。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  static const themeModeLabels = {
    ThemeMode.system: '跟随系统',
    ThemeMode.light: '浅色',
    ThemeMode.dark: '深色',
  };

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final modes = themeModeLabels.entries.toList();
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
            child: Semantics(
              header: true,
              child: Text(
                '深色模式',
                style: TextStyle(color: palette.hint, fontSize: 13),
              ),
            ),
          ),
          Material(
            color: palette.surface,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: ValueListenableBuilder<ThemeMode>(
              valueListenable: AppThemeMode.instance,
              builder: (context, current, _) => Column(
                children: [
                  for (var i = 0; i < modes.length; i++)
                    _OptionRow(
                      key: Key('settings_theme_${modes[i].key.name}'),
                      label: modes[i].value,
                      selected: modes[i].key == current,
                      showDivider: i < modes.length - 1,
                      onTap: () => AppThemeMode.instance.set(modes[i].key),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(
              '选择「跟随系统」时，App 会随手机的深色模式自动切换。',
              style: TextStyle(color: palette.hint, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单选行：文字 + 选中时右侧对勾。
class _OptionRow extends StatelessWidget {
  const _OptionRow({
    super.key,
    required this.label,
    required this.selected,
    required this.showDivider,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool showDivider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Semantics(
      inMutuallyExclusiveGroup: true,
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Column(
          children: [
            SizedBox(
              height: 52,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(
                          color: palette.titleText,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (selected)
                      Icon(Icons.check, color: palette.accent, size: 20),
                  ],
                ),
              ),
            ),
            if (showDivider)
              Divider(height: 1, indent: 16, color: palette.rowDivider),
          ],
        ),
      ),
    );
  }
}
