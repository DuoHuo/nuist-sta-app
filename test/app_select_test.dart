import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/app_select.dart';
import 'package:nuist_sta_app/core/theme.dart';

const _fieldKey = Key('select_field');
const _terms = [
  AppSelectOption(value: 1, label: '第一学期'),
  AppSelectOption(value: 2, label: '第二学期'),
  AppSelectOption(value: 3, label: '第三学期'),
];

class _ReadTrackedOption extends AppSelectOption<int> {
  const _ReadTrackedOption({
    required super.value,
    required super.label,
    super.hint,
    required this.onLabelRead,
  });

  final VoidCallback onLabelRead;

  @override
  String get label {
    onLabelRead();
    return super.label;
  }
}

List<AppSelectOption<int>> _buildings() => [
  for (var index = 1; index <= 9; index++)
    AppSelectOption(
      value: index,
      label: '楼栋 $index',
      enabled: index != 4,
      hint: index == 4 ? '暂不可选' : null,
    ),
];

Widget _host(
  Widget child, {
  bool dark = false,
  TextScaler textScaler = TextScaler.noScaling,
}) => MaterialApp(
  theme: dark ? appDarkTheme() : appLightTheme(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: textScaler, disableAnimations: true),
    child: child!,
  ),
  home: Scaffold(
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    ),
  ),
);

Widget _controlled<T>(
  ValueNotifier<T?> selected,
  List<AppSelectOption<T>> options, {
  List<T>? changes,
  String label = '学期',
  bool useBottomSheet = false,
}) => ValueListenableBuilder<T?>(
  valueListenable: selected,
  builder: (context, value, _) => AppSelectField<T>(
    key: _fieldKey,
    label: label,
    value: value,
    options: options,
    useBottomSheet: useBottomSheet,
    onChanged: (value) {
      changes?.add(value);
      selected.value = value;
    },
  ),
);

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(_fieldKey));
  await tester.pumpAndSettle();
}

Finder _searchField() => find.descendant(
  of: find.byType(BottomSheet),
  matching: find.byType(TextField),
);

void main() {
  testWidgets('短列表就地点选，更新当前值且只回调一次', (tester) async {
    final selected = ValueNotifier<int?>(1);
    addTearDown(selected.dispose);
    final changes = <int>[];
    await tester.pumpWidget(
      _host(_controlled(selected, _terms, changes: changes)),
    );

    await _open(tester);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('第二学期'), findsOneWidget);
    await tester.tap(find.text('第二学期'));
    await tester.pumpAndSettle();

    expect(selected.value, 2);
    expect(changes, [2]);
    expect(find.text('第一学期'), findsNothing);
    expect(find.text('第二学期'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('短列表的点击外部、Esc 和系统返回仅关闭菜单', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    final blockPagePop = ValueNotifier(true);
    addTearDown(blockPagePop.dispose);
    var interceptedPagePops = 0;
    final changes = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: appLightTheme(),
        home: const Scaffold(body: Text('起始页')),
      ),
    );
    navigator.currentState!.push<void>(
      MaterialPageRoute(
        builder: (_) => ValueListenableBuilder<bool>(
          valueListenable: blockPagePop,
          builder: (context, blocked, _) => PopScope<Object?>(
            canPop: !blocked,
            onPopInvokedWithResult: (didPop, result) {
              if (!didPop) interceptedPagePops++;
            },
            child: Scaffold(
              appBar: AppBar(title: const Text('选择页')),
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    AppSelectField<int>(
                      key: _fieldKey,
                      label: '学期',
                      value: 1,
                      options: _terms,
                      onChanged: changes.add,
                    ),
                    const Spacer(),
                    const Text('菜单外部'),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _open(tester);
    await tester.tapAt(tester.getCenter(find.text('菜单外部')));
    await tester.pumpAndSettle();
    expect(find.text('第二学期'), findsNothing);

    await _open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('第二学期'), findsNothing);

    await _open(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('第二学期'), findsNothing);
    expect(find.text('选择页'), findsOneWidget);
    expect(changes, isEmpty);
    expect(interceptedPagePops, 0);

    blockPagePop.value = false;
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('起始页'), findsOneWidget);
  });

  testWidgets('长列表支持搜索、清空、空结果，禁用项不能提交', (tester) async {
    final selected = ValueNotifier<int?>(1);
    addTearDown(selected.dispose);
    final changes = <int>[];
    await tester.pumpWidget(
      _host(_controlled(selected, _buildings(), label: '楼栋', changes: changes)),
    );
    await _open(tester);
    expect(find.byType(BottomSheet), findsOneWidget);

    await tester.enterText(_searchField(), '不存在的楼栋');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的选项'), findsOneWidget);
    await tester.tap(find.byTooltip('清空搜索'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_searchField()).controller!.text, isEmpty);
    expect(find.text('没有匹配的选项'), findsNothing);

    await tester.enterText(_searchField(), '楼栋 4');
    await tester.pumpAndSettle();
    expect(find.text('暂不可选'), findsOneWidget);
    await tester.tap(find.text('楼栋 4').last);
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    expect(find.byType(BottomSheet), findsOneWidget);

    await tester.enterText(_searchField(), '  楼栋 8  ');
    await tester.pumpAndSettle();
    await tester.tap(find.text('楼栋 8').last);
    await tester.pumpAndSettle();
    expect(selected.value, 8);
    expect(changes, [8]);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('空值选项与取消保持区分，菜单和底部面板行为一致', (tester) async {
    for (final sheet in [false, true]) {
      final selected = ValueNotifier<String?>('score');
      addTearDown(selected.dispose);
      final changes = <String?>[];
      await tester.pumpWidget(
        _host(
          KeyedSubtree(
            key: ValueKey(sheet),
            child: _controlled<String?>(
              selected,
              const [
                AppSelectOption(value: null, label: '所有模块'),
                AppSelectOption(value: 'score', label: '成绩模块'),
              ],
              label: '模块',
              useBottomSheet: sheet,
              changes: changes,
            ),
          ),
        ),
      );
      await _open(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(changes, isEmpty);
      expect(selected.value, 'score');

      await _open(tester);
      await tester.tap(find.text('所有模块').last);
      await tester.pumpAndSettle();
      expect(changes, [null]);
      expect(selected.value, isNull);
      expect(find.text('所有模块'), findsOneWidget);
    }
  });

  testWidgets('长选项列表首次展开不测量屏外项，键盘动画和搜索复用缓存', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 850);
    addTearDown(tester.view.reset);
    final selected = ValueNotifier<int?>(0);
    addTearDown(selected.dispose);
    var offscreenReads = 0;
    final options = [
      for (var index = 0; index < 119; index++)
        AppSelectOption(value: index, label: '选项 $index'),
      _ReadTrackedOption(
        value: 119,
        label: '选项 119',
        hint: '需要精确测量的屏外补充说明',
        onLabelRead: () => offscreenReads++,
      ),
    ];
    await tester.pumpWidget(_host(_controlled(selected, options)));
    await _open(tester);
    expect(find.text('选项 119'), findsNothing);
    final initialReads = offscreenReads;
    expect(initialReads, 1, reason: '仅建立搜索文本，未测量屏外选项');
    options.add(const AppSelectOption(value: 120, label: '打开后添加的选项'));

    await tester.tap(_searchField());
    for (final inset in [50.0, 100.0, 150.0, 200.0, 250.0, 0.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pump();
    }
    await tester.pumpAndSettle();
    // 末项始终在屏外；键盘不能重新遍历其文本或重新测量整张候选列表。
    expect(offscreenReads, initialReads);
    await tester.enterText(_searchField(), '选项 1');
    await tester.pumpAndSettle();
    expect(find.text('选项 119'), findsNothing);
    expect(offscreenReads, initialReads);
    await tester.tap(find.byTooltip('清空搜索'));
    await tester.pumpAndSettle();
    expect(offscreenReads, initialReads);
    await tester.enterText(_searchField(), '打开后添加');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的选项'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('键盘连续升起时保留搜索头部与已构建候选项', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 850);
    addTearDown(tester.view.reset);
    final selected = ValueNotifier<int?>(0);
    addTearDown(selected.dispose);
    await tester.pumpWidget(
      _host(
        _controlled(selected, [
          for (var index = 0; index < 120; index++)
            AppSelectOption(value: index, label: '选项 $index'),
        ]),
      ),
    );
    await _open(tester);
    await tester.tap(_searchField());
    await tester.pumpAndSettle();
    final search = tester.widget(_searchField());
    final rebuilds = <String, int>{};
    final previous = debugOnRebuildDirtyWidget;
    addTearDown(() => debugOnRebuildDirtyWidget = previous);
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      previous?.call(element, builtOnce);
      final name = element.widget.runtimeType.toString();
      if (name == '_OptionContent' ||
          name == 'CustomScrollView' ||
          name.startsWith('_AppSelectSheet<')) {
        rebuilds[name] = (rebuilds[name] ?? 0) + 1;
      }
    };
    for (var frame = 1; frame <= 12; frame++) {
      tester.view.viewInsets = FakeViewPadding(bottom: frame * 20.0);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(rebuilds, isEmpty, reason: '键盘 12 帧的重复构建：$rebuilds');
    expect(tester.widget(_searchField()), same(search));
    expect(tester.getRect(_searchField()).bottom, lessThan(850 - 240));
    expect(tester.takeException(), isNull);
  });

  testWidgets('选项高度缓存随面板宽度和系统字体缩放失效', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 1000);
    addTearDown(tester.view.reset);
    final selected = ValueNotifier<int?>(null);
    addTearDown(selected.dispose);
    const firstLabel = '用于查询的教学楼及附属楼层，包含需要完整显示的长选项名称';
    const firstHint = '主楼、附属教室以及更多补充说明都必须保持完整显示';
    var offscreenReads = 0;
    final options = [
      const AppSelectOption(value: 0, label: firstLabel, hint: firstHint),
      for (var index = 1; index < 119; index++)
        AppSelectOption(value: index, label: '选项 $index'),
      _ReadTrackedOption(
        value: 119,
        label: '选项 119',
        onLabelRead: () => offscreenReads++,
      ),
    ];
    Widget host({double scale = 1}) => _host(
      _controlled(selected, options),
      textScaler: TextScaler.linear(scale),
    );
    Finder firstButton() => find.ancestor(
      of: find.text(firstLabel),
      matching: find.byType(TextButton),
    );

    await tester.pumpWidget(host());
    await _open(tester);
    final wideHeight = tester.getSize(firstButton()).height;
    final initialReads = offscreenReads;

    tester.view.physicalSize = const Size(320, 1000);
    await tester.pumpAndSettle();
    final narrowHeight = tester.getSize(firstButton()).height;
    expect(narrowHeight, greaterThan(wideHeight));
    expect(offscreenReads, initialReads, reason: '变窄后仍不测量屏外项');
    final narrowReads = offscreenReads;

    await tester.pumpWidget(host(scale: 1.6));
    await tester.pumpAndSettle();
    expect(tester.getSize(firstButton()).height, greaterThan(narrowHeight));
    expect(offscreenReads, narrowReads, reason: '字体变大后仍不测量屏外项');
    expect(
      tester.getRect(find.text(firstHint)).bottom,
      lessThanOrEqualTo(tester.getRect(firstButton()).bottom),
    );
    expect(tester.takeException(), isNull);

    await tester.enterText(_searchField(), '119');
    await tester.pumpAndSettle();
    await tester.tap(find.text('选项 119'));
    await tester.pumpAndSettle();
    expect(selected.value, 119);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('长短标签混排时首次展开能定位到已选末项', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);
    final selected = ValueNotifier<int?>(119);
    addTearDown(selected.dispose);
    final options = [
      for (var index = 0; index < 120; index++)
        AppSelectOption(
          value: index,
          label: index < 30 ? '选项 $index' : '需要完整换行显示的教学楼及附属楼层选项 $index',
          hint: index < 30 ? null : '包含更多教室、楼层与场地的补充说明，不能按短选项的高度截断',
        ),
    ];
    await tester.pumpWidget(_host(_controlled(selected, options)));
    await _open(tester);
    expect(find.text(options.last.label).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text(options.last.label).hitTestable());
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(selected.value, 119);
  });

  testWidgets('禁用、加载及空列表保留提示且不响应选择', (tester) async {
    final changes = <int>[];
    await tester.pumpWidget(
      _host(
        Column(
          children: [
            AppSelectField<int>(
              key: const Key('disabled'),
              label: '楼栋',
              hint: '请先选择上一级',
              options: _terms,
              enabled: false,
              onChanged: changes.add,
            ),
            const SizedBox(height: 16),
            AppSelectField<int>(
              key: const Key('loading'),
              label: '房间',
              options: _terms,
              loading: true,
              onChanged: changes.add,
            ),
            const SizedBox(height: 16),
            AppSelectField<int>(
              key: const Key('empty'),
              label: '学期',
              hint: '暂无数据',
              options: const [],
              onChanged: changes.add,
            ),
          ],
        ),
      ),
    );
    for (final key in ['disabled', 'loading', 'empty']) {
      await tester.tap(find.byKey(Key(key)));
      await tester.pump();
    }
    expect(find.text('请先选择上一级'), findsOneWidget);
    expect(find.text('加载中…'), findsOneWidget);
    expect(find.text('暂无数据'), findsOneWidget);
    expect(find.text('第一学期'), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
    expect(changes, isEmpty);
  });

  testWidgets('表单选择参与校验、保存与重置', (tester) async {
    final form = GlobalKey<FormState>();
    int? saved;
    await tester.pumpWidget(
      _host(
        Form(
          key: form,
          child: Column(
            children: [
              AppSelectFormField<int>(
                key: _fieldKey,
                label: '学期',
                options: _terms,
                onChanged: (_) {},
                validator: (value) => value == null ? '请选择学期' : null,
                onSaved: (value) => saved = value,
              ),
              TextButton(
                onPressed: () {
                  if (form.currentState!.validate()) form.currentState!.save();
                },
                child: const Text('保存表单'),
              ),
              TextButton(
                onPressed: () => form.currentState!.reset(),
                child: const Text('重置表单'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('保存表单'));
    await tester.pumpAndSettle();
    expect(find.text('请选择学期'), findsOneWidget);
    expect(saved, isNull);

    await _open(tester);
    await tester.tap(find.text('第二学期'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存表单'));
    await tester.pumpAndSettle();
    expect(find.text('请选择学期'), findsNothing);
    expect(saved, 2);

    await tester.tap(find.text('重置表单'));
    await tester.pumpAndSettle();
    expect(find.text('第二学期'), findsNothing);
    expect(find.text('请选择'), findsOneWidget);
    expect(find.text('请选择学期'), findsNothing);
  });

  testWidgets('父组件改变表单初始值时同步显示最新值', (tester) async {
    var initialValue = 1;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) => Column(
            children: [
              AppSelectFormField<int>(
                key: _fieldKey,
                label: '学期',
                initialValue: initialValue,
                options: _terms,
                onChanged: (_) {},
              ),
              TextButton(
                onPressed: () => setState(() => initialValue = 3),
                child: const Text('更新默认学期'),
              ),
            ],
          ),
        ),
      ),
    );
    await _open(tester);
    await tester.tap(find.text('第二学期'));
    await tester.pumpAndSettle();
    expect(find.text('第二学期'), findsOneWidget);
    await tester.tap(find.text('更新默认学期'));
    await tester.pumpAndSettle();
    expect(find.text('第二学期'), findsNothing);
    expect(find.text('第三学期'), findsOneWidget);
  });

  testWidgets('级联列表更新后拒绝提交面板中已失效的选项', (tester) async {
    final options = ValueNotifier(_buildings());
    addTearDown(options.dispose);
    final changes = <int>[];
    await tester.pumpWidget(
      _host(
        ValueListenableBuilder<List<AppSelectOption<int>>>(
          valueListenable: options,
          builder: (context, items, _) => AppSelectField<int>(
            key: _fieldKey,
            label: '楼栋',
            options: items,
            value: 1,
            onChanged: changes.add,
          ),
        ),
      ),
    );
    await _open(tester);
    options.value = options.value.where((option) => option.value != 2).toList();
    await tester.pumpAndSettle();
    await tester.enterText(_searchField(), '楼栋 2');
    await tester.pumpAndSettle();
    await tester.tap(find.text('楼栋 2').last);
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    expect(find.text('楼栋 1'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('窄屏大字与横屏键盘下可滚动搜索并选择长标签', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const label = '用于查询的教学楼及附属楼层';
    const hint = '包含主楼、附属教室与需要完整显示的补充说明';
    for (final scenario in [
      (size: const Size(320, 700), scale: 2.0, keyboard: 280.0),
      (size: const Size(700, 360), scale: 1.6, keyboard: 220.0),
    ]) {
      tester.view.physicalSize = scenario.size;
      tester.view.viewInsets = const FakeViewPadding();
      final selected = ValueNotifier<int?>(1);
      addTearDown(selected.dispose);
      await tester.pumpWidget(
        _host(
          KeyedSubtree(
            key: ValueKey(scenario.size),
            child: _controlled(selected, [
              for (var index = 1; index <= 9; index++)
                AppSelectOption(
                  value: index,
                  label: '$label $index',
                  hint: hint,
                ),
            ], label: '选择教学楼'),
          ),
          textScaler: TextScaler.linear(scenario.scale),
        ),
      );
      await _open(tester);
      await tester.tap(_searchField());
      await tester.enterText(_searchField(), '教学楼');
      await tester.pumpAndSettle();
      final searchController = tester
          .widget<TextField>(_searchField())
          .controller!;
      searchController.selection = const TextSelection.collapsed(offset: 1);
      await tester.pump();
      final searchElement = tester.element(_searchField());
      final focused = FocusManager.instance.primaryFocus;
      for (var frame = 1; frame <= 12; frame++) {
        tester.view.viewInsets = FakeViewPadding(
          bottom: scenario.keyboard * frame / 12,
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
      expect(tester.element(_searchField()), same(searchElement));
      expect(FocusManager.instance.primaryFocus, same(focused));
      expect(searchController.text, '教学楼');
      expect(searchController.selection.baseOffset, 1);
      await tester.ensureVisible(_searchField());
      await tester.pumpAndSettle();
      expect(
        tester.getRect(_searchField()).bottom,
        lessThanOrEqualTo(scenario.size.height - scenario.keyboard + 1),
      );
      await tester.enterText(_searchField(), '9');
      await tester.pumpAndSettle();
      // 横屏键盘下，头部与结果共用滚动区域；先滚到结果，才会构建屏幕外的选项。
      await tester.scrollUntilVisible(
        find.text('$label 9'),
        64,
        scrollable: find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('$label 9'), findsOneWidget);
      expect(find.text(hint), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('$label 9'));
      await tester.pumpAndSettle();
      expect(find.text('$label 9').hitTestable(), findsOneWidget);
      await tester.tap(find.text('$label 9'));
      await tester.pumpAndSettle();
      expect(selected.value, 9);
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('深色主题保持文字对比，键盘可打开并完成选择', (tester) async {
    final selected = ValueNotifier<int?>(1);
    addTearDown(selected.dispose);
    await tester.pumpWidget(_host(_controlled(selected, _terms), dark: true));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(find.text('第二学期'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected.value, 2);

    final field = find.byKey(_fieldKey);
    final text = tester.widget<Text>(
      find.descendant(of: field, matching: find.text('第二学期')),
    );
    final surface = tester.widget<Material>(
      find.descendant(of: field, matching: find.byType(Material)),
    );
    final foregroundLuminance = text.style!.color!.computeLuminance();
    final backgroundLuminance = surface.color!.computeLuminance();
    expect(backgroundLuminance, lessThan(0.1));
    expect(
      (foregroundLuminance + 0.05) / (backgroundLuminance + 0.05),
      greaterThanOrEqualTo(4.5),
    );
    expect(tester.takeException(), isNull);
  });
}
