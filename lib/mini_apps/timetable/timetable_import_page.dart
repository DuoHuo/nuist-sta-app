import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_snack_bar.dart';
import '../../core/colors.dart';
import '../../core/logging/app_log.dart';
import '../../core/privacy/privacy_consent_dialog.dart';
import 'timetable_controller.dart';
import 'timetable_import_api.dart';
import 'timetable_import_models.dart';
import 'timetable_multi_models.dart';
import 'timetable_persistence_feedback.dart';

/// WakeUp 口令导入页：粘贴口令 → 解析预览 → 命名并导入为独立课表。
class TimetableImportPage extends StatefulWidget {
  const TimetableImportPage({super.key, this.controller, this.api});

  final TimetableController? controller;
  final TimetableImportApi? api;

  @override
  State<TimetableImportPage> createState() => _TimetableImportPageState();
}

class _TimetableImportPageState extends State<TimetableImportPage> {
  static final _log = AppLog.logger('timetable.import');

  late final TimetableImportApi _api;
  final _cancelToken = CancelToken();
  final _inputController = TextEditingController();
  final _nameController = TextEditingController();

  WakeupImportResult? _preview;
  String? _error;
  bool _mockPrompt = false;
  bool _parsing = false;
  bool _saving = false;
  bool _setAsPrimary = false;

  TimetableController get _host =>
      widget.controller ?? TimetableController.instance;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? TimetableImportApi();
  }

  @override
  void dispose() {
    _cancelToken.cancel();
    if (widget.api == null) _api.close();
    _inputController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text ?? '';
      if (!mounted) return;
      if (text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          AppSnackBar(
            tone: AppSnackBarTone.info,
            content: const Text('剪贴板暂无文本内容'),
          ),
        );
        return;
      }
      setState(() {
        _inputController.text = text;
        _error = null;
        _mockPrompt = false;
      });
    } catch (_) {}
  }

  void _fillDemoToken() {
    setState(() {
      _inputController.text = TimetableImportApi.demoShareText;
      _error = null;
      _mockPrompt = false;
    });
  }

  Future<void> _parse() async {
    if (_parsing) return;
    FocusScope.of(context).unfocus();
    // 真实口令要发到社团服务器解析，必须先同意隐私政策；内置演示口令只在本地解析，不拦截。
    if (!TimetableImportApi.isMockShareKey(
      extractWakeupShareKey(_inputController.text),
    )) {
      final agreed = await ensurePrivacyConsent(
        context,
        reason: '导入课表会把口令发送到社团服务器，再由其向 WakeUp 分享服务解析。需要先同意',
      );
      if (!agreed || !mounted) return;
    }
    setState(() {
      _parsing = true;
      _error = null;
      _mockPrompt = false;
    });
    try {
      final result = await _log.operation(
        'parse',
        () => _api.fetchByShareText(
          _inputController.text,
          cancelToken: _cancelToken,
        ),
        fields: {'input_length': _inputController.text.trim().length},
        resultFields: (r) => {
          'course_count': r.courseCount,
          'slot_count': r.slotCount,
          'is_mock': r.isMock,
        },
        failureEvent: 'parse.failed',
      );
      if (!mounted) return;
      setState(() {
        _preview = result;
        _nameController.text = result.defaultName;
      });
    } on TimetableImportException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _mockPrompt = error.mockSupported;
        _preview = null;
      });
    } on DioException {
      // 页面退出取消请求时不提示。
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '解析口令失败，请稍后重试';
        _preview = null;
      });
    } finally {
      if (mounted) setState(() => _parsing = false);
    }
  }

  Future<void> _confirmImport() async {
    final preview = _preview;
    if (preview == null || _saving) return;
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请填写导入后的课表名称');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final meta = await withTimetablePersistenceFeedback<ScheduleMetadata>(
      context,
      () => _host.importWakeupSchedule(
        preview,
        name: name,
        setAsPrimary: _setAsPrimary,
      ),
      onError: (msg) => setState(() => _error = msg),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (meta != null) {
      Navigator.of(context).pop(meta);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final preview = _preview;
    return Scaffold(
      backgroundColor: palette.pageBg,
      appBar: AppBar(title: const Text('从口令导入')),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  '粘贴课表分享文案或 32 位口令（兼容 WakeUp 格式），解析后将保存为「导入的课表」，与你自己的教务课表分开管理。',
                  style: TextStyle(
                    fontSize: 13,
                    color: palette.hint,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('tt_import_input'),
                  controller: _inputController,
                  minLines: 3,
                  maxLines: 5,
                  enabled: !_parsing && !_saving,
                  decoration: InputDecoration(
                    labelText: '分享口令或完整文案',
                    hintText: '例如：分享口令为「...」',
                    border: const OutlineInputBorder(),
                    filled: true,
                    fillColor: palette.surface,
                  ),
                  onChanged: (_) {
                    if (_error != null) {
                      setState(() {
                        _error = null;
                        _mockPrompt = false;
                      });
                    }
                  },
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ActionChip(
                      key: const Key('tt_import_paste_chip'),
                      avatar: const Icon(Icons.content_paste, size: 16),
                      label: const Text('粘贴剪贴板'),
                      onPressed: _parsing || _saving
                          ? null
                          : _pasteFromClipboard,
                    ),
                    ActionChip(
                      key: const Key('tt_import_demo_chip'),
                      avatar: const Icon(Icons.science_outlined, size: 16),
                      label: const Text('填入示例口令 (Mock)'),
                      onPressed: _parsing || _saving ? null : _fillDemoToken,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  key: const Key('tt_import_parse_btn'),
                  onPressed: _parsing || _saving ? null : _parse,
                  icon: _parsing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_outlined),
                  label: Text(_parsing ? '正在解析…' : '解析口令'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(
                    _error!,
                    key: const Key('tt_import_error'),
                    style: TextStyle(color: palette.danger, fontSize: 13),
                  ),
                  if (_mockPrompt) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton(
                        key: const Key('tt_import_try_mock_btn'),
                        onPressed: _parsing
                            ? null
                            : () {
                                _fillDemoToken();
                                _parse();
                              },
                        child: const Text('使用示例口令体验 Mock 导入'),
                      ),
                    ),
                  ],
                ],
                if (preview != null) ...[
                  const SizedBox(height: 24),
                  Material(
                    key: const Key('tt_import_preview'),
                    color: palette.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: BorderSide(color: palette.divider),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '课表预览',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: palette.titleText,
                                  ),
                                ),
                              ),
                              if (preview.isMock)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: palette.accent.withValues(
                                      alpha: 0.14,
                                    ),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    'Mock 示例',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: palette.accent,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            [
                              if (preview.courseCount > 0)
                                '${preview.courseCount} 门课程',
                              if (preview.slotCount > 0)
                                '${preview.slotCount} 个时段',
                              if (preview.examCount > 0)
                                '${preview.examCount} 场考试',
                              '共 ${preview.snapshot.settings.maxWeeks} 周',
                            ].join(' · '),
                            style: TextStyle(
                              fontSize: 13,
                              color: palette.labelText,
                            ),
                          ),
                          for (final warning in preview.warnings) ...[
                            const SizedBox(height: 6),
                            Text(
                              warning,
                              style: TextStyle(
                                fontSize: 12,
                                color: palette.warning,
                              ),
                            ),
                          ],
                          const SizedBox(height: 14),
                          TextField(
                            key: const Key('tt_import_name_input'),
                            controller: _nameController,
                            enabled: !_saving,
                            maxLength: 24,
                            decoration: const InputDecoration(
                              labelText: '课表名称（可自定义，如「室友课表」）',
                              border: OutlineInputBorder(),
                              counterText: '',
                            ),
                          ),
                          const SizedBox(height: 8),
                          SwitchListTile.adaptive(
                            key: const Key('tt_import_set_primary'),
                            contentPadding: EdgeInsets.zero,
                            title: const Text('同时设为主课表'),
                            subtitle: Text(
                              '主课表将用于首页卡片、桌面小组件与上课提醒',
                              style: TextStyle(
                                fontSize: 12,
                                color: palette.hint,
                              ),
                            ),
                            value: _setAsPrimary,
                            onChanged: _saving
                                ? null
                                : (v) => setState(() => _setAsPrimary = v),
                          ),
                          const Divider(height: 16),
                          for (final course in preview.snapshot.courses.take(6))
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      course.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: palette.titleText,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '${course.slots.length} 个时段',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: palette.hint,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (preview.snapshot.courses.length > 6)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                '还有 ${preview.snapshot.courses.length - 6} 门课程…',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: palette.hint,
                                ),
                              ),
                            ),
                          const SizedBox(height: 16),
                          FilledButton(
                            key: const Key('tt_import_confirm_btn'),
                            onPressed: _saving ? null : _confirmImport,
                            child: Text(_saving ? '正在导入…' : '导入并查看'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
