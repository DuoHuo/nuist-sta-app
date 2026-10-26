import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/colors.dart';
import 'timetable_controller.dart';
import 'timetable_export_api.dart';
import 'timetable_export_models.dart';

/// WakeUp 导出页：预览范围、生成口令与复制分享文本。
class TimetableExportPage extends StatefulWidget {
  const TimetableExportPage({super.key, required this.controller, this.api});

  final TimetableController controller;
  final TimetableExportApi? api;

  @override
  State<TimetableExportPage> createState() => _TimetableExportPageState();
}

class _TimetableExportPageState extends State<TimetableExportPage> {
  late final TimetableExportApi _api;
  final _cancelToken = CancelToken();
  TimetableExportSnapshot? _snapshot;
  TimetableWakeupShare? _share;
  String? _error;
  bool _generating = false;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? TimetableExportApi();
    try {
      _snapshot = TimetableExportSnapshot.fromController(widget.controller);
    } on TimetableExportException catch (error) {
      _error = error.message;
    }
  }

  @override
  void dispose() {
    _cancelToken.cancel();
    if (widget.api == null) _api.close();
    super.dispose();
  }

  Future<void> _generate() async {
    final snapshot = _snapshot;
    if (_generating || snapshot == null) return;
    setState(() {
      _generating = true;
      _error = null;
    });
    try {
      final share = await _api.generate(snapshot, cancelToken: _cancelToken);
      if (mounted) {
        setState(() => _share = share);
        await _copy(share.shareText, '已复制口令');
      }
    } on TimetableExportException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on DioException catch (_) {
      // 页面退出取消请求时，无需提示。
    } catch (_) {
      if (mounted) setState(() => _error = '生成口令失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _copy(String text, String message) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('复制失败，请长按口令手动复制')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final snapshot = _snapshot;
    final share = _share;
    return Scaffold(
      backgroundColor: palette.pageBg,
      appBar: AppBar(title: const Text('导出到 WakeUp')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (snapshot != null) ...[
            Text(
              snapshot.payload['name'] as String,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: palette.titleText,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '${snapshot.courseCount} 门课程、${snapshot.examCount} 场考试、${snapshot.otherCount} 个其他日程。',
              style: TextStyle(color: palette.labelText),
            ),
            for (final warning in snapshot.warnings) ...[
              const SizedBox(height: 12),
              Text(warning, style: TextStyle(color: palette.warning)),
            ],
          ],
          if (_error != null) ...[
            const SizedBox(height: 20),
            Text(
              _error!,
              key: const Key('timetable_export_error'),
              style: TextStyle(color: palette.danger),
            ),
          ],
          if (snapshot != null && share == null) ...[
            const SizedBox(height: 24),
            FilledButton.icon(
              key: const Key('timetable_export_generate'),
              onPressed: _generating ? null : _generate,
              icon: _generating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.ios_share),
              label: Text(
                _generating
                    ? '正在生成…'
                    : _error == null
                    ? '生成 WakeUp 口令'
                    : '重新生成',
              ),
            ),
          ],
          if (share != null) ...[
            const SizedBox(height: 24),
            SelectableText(
              share.shareText,
              key: const Key('timetable_export_share_id'),
              style: TextStyle(
                fontSize: 15,
                color: palette.labelText,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => _copy(share.shareText, '已复制口令'),
              icon: const Icon(Icons.copy_outlined),
              label: const Text('复制口令'),
            ),
          ],
        ],
      ),
    );
  }
}
