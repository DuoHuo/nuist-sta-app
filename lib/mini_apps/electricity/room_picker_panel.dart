import 'package:flutter/material.dart';

import '../../core/auth/portal_exceptions.dart';
import '../../core/colors.dart';
import 'electricity_api.dart';
import 'electricity_models.dart';

/// 区域 → 楼栋 → 房间三级下拉，列表全部从服务器拉取。
///
/// 只负责选，选完通过 [onSave] 交出去；展开/收起动画由外层控制。
class RoomPickerPanel extends StatefulWidget {
  const RoomPickerPanel({
    super.key,
    required this.initial,
    required this.onSave,
    required this.onCancel,
  });

  final ElecRoom? initial;
  final Future<void> Function(ElecRoom room) onSave;
  final VoidCallback onCancel;

  @override
  State<RoomPickerPanel> createState() => _RoomPickerPanelState();
}

class _RoomPickerPanelState extends State<RoomPickerPanel> {
  List<ElecOption>? _campuses;
  List<ElecOption>? _buildings;
  List<ElecOption>? _rooms;
  ElecOption? _campus;
  ElecOption? _building;
  ElecOption? _room;

  /// 正在加载的那一级（0/1/2），null 表示空闲。
  int? _loadingLevel;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadCampuses();
  }

  Future<void> _guard(int level, Future<void> Function() task) async {
    setState(() {
      _loadingLevel = level;
      _error = null;
    });
    try {
      await task();
    } on PortalException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '加载失败：$e');
    } finally {
      if (mounted) setState(() => _loadingLevel = null);
    }
  }

  /// 首次打开时把已绑定的宿舍逐级预选出来，用户只想改房间号就不必从区域重选。
  Future<void> _loadCampuses() => _guard(0, () async {
    final list = await ElectricityApi.listCampuses();
    if (!mounted) return;
    setState(() => _campuses = list);
    final preset = widget.initial;
    if (preset == null) return;
    final campus = _match(list, preset.campus);
    if (campus == null) return;
    setState(() => _campus = campus);
    final buildings = await ElectricityApi.listBuildings(campus);
    if (!mounted) return;
    setState(() => _buildings = buildings);
    final building = _match(buildings, preset.building);
    if (building == null) return;
    setState(() => _building = building);
    final rooms = await ElectricityApi.listRooms(campus, building);
    if (!mounted) return;
    setState(() {
      _rooms = rooms;
      _room = _match(rooms, preset.room);
    });
  });

  static ElecOption? _match(List<ElecOption> list, ElecOption target) {
    for (final item in list) {
      if (item.value == target.value) return item;
    }
    return null;
  }

  void _selectCampus(ElecOption? campus) {
    if (campus == null || campus == _campus) return;
    setState(() {
      _campus = campus;
      _building = null;
      _room = null;
      _buildings = null;
      _rooms = null;
    });
    _guard(1, () async {
      final list = await ElectricityApi.listBuildings(campus);
      if (mounted && _campus == campus) setState(() => _buildings = list);
    });
  }

  void _selectBuilding(ElecOption? building) {
    final campus = _campus;
    if (building == null || campus == null || building == _building) return;
    setState(() {
      _building = building;
      _room = null;
      _rooms = null;
    });
    _guard(2, () async {
      final list = await ElectricityApi.listRooms(campus, building);
      if (mounted && _building == building) setState(() => _rooms = list);
    });
  }

  Future<void> _save() async {
    final campus = _campus, building = _building, room = _room;
    if (campus == null || building == null || room == null) return;
    setState(() => _saving = true);
    try {
      await widget.onSave(
        ElecRoom(campus: campus, building: building, room: room),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canSave =
        _campus != null && _building != null && _room != null && !_saving;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Dropdown(
            label: '区域',
            items: _campuses,
            value: _campus,
            loading: _loadingLevel == 0,
            enabled: true,
            onChanged: _selectCampus,
          ),
          const SizedBox(height: 10),
          _Dropdown(
            label: '楼栋',
            items: _buildings,
            value: _building,
            loading: _loadingLevel == 1,
            enabled: _campus != null,
            onChanged: _selectBuilding,
          ),
          const SizedBox(height: 10),
          _Dropdown(
            label: '房间',
            items: _rooms,
            value: _room,
            loading: _loadingLevel == 2,
            enabled: _building != null,
            onChanged: (v) => setState(() => _room = v),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.error,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _saving ? null : widget.onCancel,
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: canSave ? _save : null,
                child: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('保存'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Dropdown extends StatelessWidget {
  const _Dropdown({
    required this.label,
    required this.items,
    required this.value,
    required this.loading,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final List<ElecOption>? items;
  final ElecOption? value;
  final bool loading;
  final bool enabled;
  final ValueChanged<ElecOption?> onChanged;

  @override
  Widget build(BuildContext context) {
    final options = items ?? const <ElecOption>[];
    final active = enabled && !loading && options.isNotEmpty;
    return Row(
      children: [
        SizedBox(
          width: 44,
          child: Text(
            label,
            style: const TextStyle(fontSize: 14, color: AppColors.labelText),
          ),
        ),
        Expanded(
          child: Container(
            height: 40,
            padding: const EdgeInsets.only(left: 12, right: 8),
            decoration: BoxDecoration(
              color: AppColors.pageBg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<ElecOption>(
                value: value,
                isExpanded: true,
                items: [
                  for (final item in options)
                    DropdownMenuItem(
                      value: item,
                      child: Text(item.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: active ? onChanged : null,
                hint: Text(
                  loading
                      ? '加载中…'
                      : !enabled
                      ? '请先选择上一级'
                      : options.isEmpty && items != null
                      ? '暂无数据'
                      : '请选择',
                  style: const TextStyle(fontSize: 14, color: AppColors.hint),
                ),
                style: const TextStyle(fontSize: 14, color: AppColors.titleText),
                icon: loading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        Icons.expand_more,
                        color: active ? AppColors.labelText : AppColors.hint,
                      ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
