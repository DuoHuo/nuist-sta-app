part of 'sunshine_run_page.dart';

class _DialogFrame extends StatelessWidget {
  const _DialogFrame({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Dialog(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: palette.divider),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          title,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: palette.titleText,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭$title',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: Icon(
                        Icons.close_rounded,
                        size: 20,
                        color: palette.labelText,
                      ),
                      padding: const EdgeInsets.all(8),
                      constraints: const BoxConstraints(
                        minHeight: 40,
                        minWidth: 40,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DialogNote extends StatelessWidget {
  const _DialogNote(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontSize: 12,
      height: 1.55,
      color: _RunColors(AppPalette.of(context)).hint,
    ),
  );
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.label,
    required this.controller,
    required this.onChanged,
    required this.fieldKey,
    this.autofocus = false,
    this.onSubmit,
  });
  final String label;
  final TextEditingController controller;
  final VoidCallback onChanged;
  final Key fieldKey;
  final bool autofocus;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: palette.labelText,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          key: fieldKey,
          controller: controller,
          autofocus: autofocus,
          keyboardType: TextInputType.number,
          textInputAction: onSubmit == null
              ? TextInputAction.next
              : TextInputAction.done,
          onChanged: (_) => onChanged(),
          onSubmitted: (_) => onSubmit == null
              ? FocusScope.of(context).nextFocus()
              : onSubmit!(),
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: palette.titleText,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
          decoration: InputDecoration(
            filled: true,
            fillColor: palette.pageBg,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 12,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: palette.divider),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: palette.divider),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: palette.accent, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}

class _PreviewBox extends StatelessWidget {
  const _PreviewBox(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.pageBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.divider),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: palette.labelText, height: 1.55),
      ),
    );
  }
}

class _FormError extends StatelessWidget {
  const _FormError(this.error);
  final String? error;

  @override
  Widget build(BuildContext context) => error == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Semantics(
            liveRegion: true,
            child: Text(
              error!,
              style: TextStyle(
                fontSize: 12,
                color: _RunColors(AppPalette.of(context)).danger,
                height: 1.5,
              ),
            ),
          ),
        );
}

class _EditorActions extends StatelessWidget {
  const _EditorActions({required this.onSave, this.saveLabel = '保存'});
  final VoidCallback onSave;
  final String saveLabel;

  @override
  Widget build(BuildContext context) {
    final colors = _RunColors(AppPalette.of(context));
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 8,
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(
              foregroundColor: AppPalette.of(context).labelText,
            ),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: onSave,
            style: FilledButton.styleFrom(
              backgroundColor: colors.action,
              foregroundColor: AppPalette.of(context).surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(9),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
            ),
            child: Text(saveLabel),
          ),
        ],
      ),
    );
  }
}

class _CountEditor extends StatefulWidget {
  const _CountEditor({required this.state, this.activity, this.custom});
  final SunshineRunState state;
  final SunshineRunActivity? activity;
  final SunshineRunCustomActivity? custom;

  @override
  State<_CountEditor> createState() => _CountEditorState();
}

class _CountEditorState extends State<_CountEditor> {
  late final _total = TextEditingController(text: '${widget.state.baseTotal}');
  late final _morning = TextEditingController(
    text: '${widget.state.baseMorning}',
  );
  late final _count = TextEditingController(
    text:
        '${widget.custom?.count ?? widget.state.activities[widget.activity?.id] ?? 0}',
  );
  String? _error;
  bool get _baseline => widget.activity == null;

  @override
  void dispose() {
    _total.dispose();
    _morning.dispose();
    _count.dispose();
    super.dispose();
  }

  void _changed() => setState(() => _error = null);

  SunshineRunState _next() {
    if (_baseline) {
      return widget.state.withBaseline(
        parseSunshineRunCount(_total.text, label: '已有总次数'),
        parseSunshineRunCount(_morning.text, label: '已有晨跑次数'),
      );
    }
    final count = parseSunshineRunCount(_count.text, label: '参加场次');
    return widget.custom == null
        ? widget.state.withActivity(widget.activity!.id, count)
        : widget.state.withCustomCount(widget.custom!.id, count);
  }

  String get _preview {
    try {
      final result = _next().calculate();
      return '保存后累计：总次数 ${result.total} 次，其中晨跑 ${result.morning} 次。\n${_baseline ? '已有次数作为基数，下方活动场次继续保留。' : '按实际参加场次录入，每场折算会自动叠加。'}';
    } on FormatException catch (error) {
      return error.message;
    }
  }

  void _preset(int? add) {
    try {
      var current = 0;
      try {
        current = parseSunshineRunCount(_count.text);
      } on FormatException {
        // 与前端一致：无效草稿点快捷增加时从零开始填写。
      }
      _count.text = '${add == null ? 0 : parseSunshineRunCount(current + add)}';
      _changed();
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  void _save() {
    try {
      Navigator.of(context).pop(_next());
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final colors = _RunColors(palette);
    final activity = widget.activity;
    return _DialogFrame(
      title: _baseline ? '录入已有次数' : '修改 ${activity!.label}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DialogNote(
            _baseline
                ? '填写使用计算器前已累计的次数，下方活动场次会自动叠加。'
                : '按实际参加场次填写（每场总次数 +${activity!.total}${activity.morning > 0 ? '，晨跑 +${activity.morning}' : ''}）。',
          ),
          const SizedBox(height: 16),
          if (_baseline) ...[
            _NumberField(
              label: '已有总次数（含晨跑）',
              controller: _total,
              onChanged: _changed,
              fieldKey: const ValueKey('sunshine-base-total'),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            _NumberField(
              label: '其中晨跑次数',
              controller: _morning,
              onChanged: _changed,
              fieldKey: const ValueKey('sunshine-base-morning'),
              onSubmit: _save,
            ),
            if (widget.state.baseTotal > 0)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () {
                    _total.text = '0';
                    _morning.text = '0';
                    _changed();
                  },
                  style: TextButton.styleFrom(foregroundColor: colors.danger),
                  child: const Text('清零已有'),
                ),
              ),
          ] else ...[
            _NumberField(
              label: '参加场次',
              controller: _count,
              onChanged: _changed,
              fieldKey: const ValueKey('sunshine-activity-input'),
              autofocus: true,
              onSubmit: _save,
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final add in [1, 5, 10])
                  TextButton(
                    onPressed: () => _preset(add),
                    style: TextButton.styleFrom(
                      foregroundColor: colors.action,
                      backgroundColor: colors.accentSoft,
                    ),
                    child: Text('+$add 场'),
                  ),
                TextButton(
                  onPressed: () => _preset(null),
                  style: TextButton.styleFrom(
                    foregroundColor: colors.danger,
                    backgroundColor: colors.sunSoft,
                  ),
                  child: const Text('清零'),
                ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          _PreviewBox(_preview),
          _FormError(_error),
          _EditorActions(onSave: _save),
        ],
      ),
    );
  }
}

class _CustomEditor extends StatefulWidget {
  const _CustomEditor({required this.state, this.initial});
  final SunshineRunState state;
  final SunshineRunCustomActivity? initial;

  @override
  State<_CustomEditor> createState() => _CustomEditorState();
}

class _CustomEditorState extends State<_CustomEditor> {
  late final _name = TextEditingController(text: widget.initial?.label ?? '');
  late final _total = TextEditingController(
    text: '${widget.initial?.total ?? 1}',
  );
  late final _morning = TextEditingController(
    text: '${widget.initial?.morning ?? 0}',
  );
  late final _count = TextEditingController(
    text: '${widget.initial?.count ?? 1}',
  );
  late final String _id = _draftId();
  String? _error;

  String _draftId() {
    if (widget.initial != null) return widget.initial!.id;
    var index = 0;
    while (widget.state.customActivities.any((a) => a.id == 'draft-$index')) {
      index++;
    }
    return 'draft-$index';
  }

  @override
  void dispose() {
    _name.dispose();
    _total.dispose();
    _morning.dispose();
    _count.dispose();
    super.dispose();
  }

  void _changed() => setState(() => _error = null);

  SunshineRunCustomActivity _next() {
    final next = SunshineRunCustomActivity(
      id: _id,
      label: _name.text.trim().isEmpty ? '其他活动' : _name.text.trim(),
      total: parseSunshineRunCount(_total.text, positive: true, label: '每场总次数'),
      morning: parseSunshineRunCount(_morning.text, label: '每场晨跑次数'),
      count: parseSunshineRunCount(_count.text, label: '参加场次'),
    );
    // 同时检查折算乘法、累计上界及晨跑子集，避免弹层先关掉才发现非法输入。
    if (widget.initial == null) {
      widget.state.withCustomAdded(next);
    } else {
      widget.state.withCustomUpdated(next);
    }
    return next;
  }

  String get _preview {
    try {
      final next = _next();
      return '当前将计入：总次数 +${next.total * next.count} 次${next.morning > 0 ? '，其中晨跑 +${next.morning * next.count} 次' : ''}。';
    } on FormatException catch (error) {
      return error.message;
    }
  }

  void _save() {
    try {
      Navigator.of(context).pop(_next());
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return _DialogFrame(
      title: widget.initial == null ? '添加其他活动' : '编辑其他活动',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _DialogNote('自定义单场活动折算的总次数与晨跑次数（晨跑已计入总次数）。'),
          const SizedBox(height: 16),
          Text(
            '活动名称（选填）',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: palette.labelText,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            key: const ValueKey('sunshine-custom-name'),
            controller: _name,
            autofocus: true,
            maxLength: 30,
            textInputAction: TextInputAction.next,
            onChanged: (_) => _changed(),
            onSubmitted: (_) => FocusScope.of(context).nextFocus(),
            style: TextStyle(fontSize: 15, color: palette.titleText),
            decoration: InputDecoration(
              hintText: '如：志愿者、健身操',
              hintStyle: TextStyle(color: _RunColors(palette).hint),
              counterText: '',
              filled: true,
              fillColor: palette.pageBg,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: palette.divider),
              ),
            ),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final total = _NumberField(
                label: '每场总次数',
                controller: _total,
                onChanged: _changed,
                fieldKey: const ValueKey('sunshine-custom-total'),
              );
              final morning = _NumberField(
                label: '其中晨跑次数',
                controller: _morning,
                onChanged: _changed,
                fieldKey: const ValueKey('sunshine-custom-morning'),
              );
              if (constraints.maxWidth < 330 ||
                  MediaQuery.textScalerOf(context).scale(14) > 19) {
                return Column(
                  children: [total, const SizedBox(height: 12), morning],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: total),
                  const SizedBox(width: 12),
                  Expanded(child: morning),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          _NumberField(
            label: '参加场次',
            controller: _count,
            onChanged: _changed,
            fieldKey: const ValueKey('sunshine-custom-count'),
            onSubmit: _save,
          ),
          const SizedBox(height: 14),
          _PreviewBox(_preview),
          _FormError(_error),
          _EditorActions(
            onSave: _save,
            saveLabel: widget.initial == null ? '添加' : '保存',
          ),
        ],
      ),
    );
  }
}

class _ResetDialog extends StatelessWidget {
  const _ResetDialog({required this.state});
  final SunshineRunState state;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final colors = _RunColors(palette);
    final added = state.calculate().addedTotal;
    Widget option(
      String action,
      String title,
      String detail, {
      bool danger = false,
      bool enabled = true,
    }) => OutlinedButton(
      onPressed: enabled ? () => Navigator.of(context).pop(action) : null,
      style: OutlinedButton.styleFrom(
        foregroundColor: danger ? colors.danger : palette.titleText,
        padding: const EdgeInsets.all(14),
        alignment: Alignment.centerLeft,
        side: BorderSide(color: palette.divider),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            detail,
            style: TextStyle(
              fontSize: 12,
              color: enabled ? colors.hint : palette.hint,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
    return _DialogFrame(
      title: '重置记录',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _DialogNote('选择要清空的范围，操作后可在底部提示中一键撤销。'),
          const SizedBox(height: 16),
          option(
            'activities',
            '仅清空新增活动场次',
            added > 0 ? '清空当前新增的 $added 次活动，保留已有次数与设置' : '当前暂无新增活动场次',
            enabled: added > 0,
          ),
          const SizedBox(height: 10),
          option('all', '清空全部跑步记录', '将已有次数与所有活动场次归零，保留年级设置', danger: true),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
          ),
        ],
      ),
    );
  }
}

class _RulesDialog extends StatelessWidget {
  const _RulesDialog({required this.state});
  final SunshineRunState state;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final colors = _RunColors(palette);
    const rules = [
      (1, SunshineRunExemption.none, '大一', '36 次（晨跑 12）', '晨跑 12 次'),
      (1, SunshineRunExemption.half, '大一半免', '18 次（晨跑 12）', '晨跑 12 次'),
      (2, SunshineRunExemption.none, '大二', '48 次（晨跑 15）', '24 次（晨跑 15）'),
      (2, SunshineRunExemption.half, '大二半免', '24 次（晨跑 15）', '12 次（晨跑 15）'),
    ];
    Widget heading(String title) => Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: palette.titleText,
        ),
      ),
    );
    Widget line(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        '• $text',
        style: TextStyle(fontSize: 12, color: palette.labelText, height: 1.55),
      ),
    );
    return _DialogFrame(
      title: '计算规则',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _DialogNote('总次数包含晨跑。例如 1 次普通晨跑计为总次数 +1、其中晨跑 +1。'),
          heading('单场活动折算'),
          for (final activity in kSunshineRunActivities)
            line(
              '${activity.label}：总次数 +${activity.total}${activity.morning > 0 ? '，其中晨跑 +${activity.morning}' : ''}',
            ),
          line('其他自定义活动：按自定义每场总次数与晨跑次数折算'),
          heading('年级与减免标准'),
          for (final rule in rules) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: state.grade == rule.$1 && state.exemption == rule.$2
                    ? colors.accentSoft
                    : palette.pageBg,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: palette.divider),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    rule.$3,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color:
                          state.grade == rule.$1 && state.exemption == rule.$2
                          ? colors.action
                          : palette.titleText,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '满分：${rule.$4}\n达标：${rule.$5}',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.55,
                      color: palette.labelText,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
          ],
          const _DialogNote('大二半免仍需 15 次晨跑，因此达标时总次数自然至少为 15。全免无需跑步。'),
          heading('使用说明'),
          line('总次数完成率最高显示 100%，达标与满分仍会校验晨跑次数。'),
          line('“已有次数”作为基数，下方活动场次累加在其上。'),
          line('年级自动使用现有身份与校历信息识别；信息不可用时可手动选择。切换年级或减免不会修改跑步记录。'),
          line('支持提示中的“撤销”，以及外接键盘 Ctrl/⌘+Z。'),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              style: FilledButton.styleFrom(
                backgroundColor: colors.action,
                foregroundColor: palette.surface,
              ),
              child: const Text('知道了'),
            ),
          ),
        ],
      ),
    );
  }
}
