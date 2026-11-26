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

List<AppSelectOption<int>> _buildings() => [
  for (var index = 1; index <= 9; index++)
    AppSelectOption(
      value: index,
      label: '楼栋 $index',
      enabled: index != 4,
      hint: index == 4 ? '暂不可选' : null,
    ),
];

Widget _host(Widget child, {bool dark = false}) => MaterialApp(
  theme: dark ? appDarkTheme() : appLightTheme(),
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
}) => ValueListenableBuilder<T?>(
  valueListenable: selected,
  builder: (context, value, _) => AppSelectField<T>(
    key: _fieldKey,
    label: label,
    value: value,
    options: options,
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

Finder _searchField() => find.byWidgetPredicate(
  (widget) =>
      widget is TextField &&
      (widget.decoration?.hintText?.startsWith('搜索') ?? false),
);

void main() {
  testWidgets('短列表点选更新并仅回调一次，点击外部/Esc/系统返回关闭菜单', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    final blockPagePop = ValueNotifier(true);
    addTearDown(blockPagePop.dispose);
    final selected = ValueNotifier<int?>(1);
    addTearDown(selected.dispose);
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
                    _controlled(selected, _terms, changes: changes),
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
    expect(_searchField(), findsNothing);
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
    expect(changes, isEmpty);
    expect(interceptedPagePops, 0);

    await _open(tester);
    await tester.tap(find.text('第二学期'));
    await tester.pumpAndSettle();
    expect(selected.value, 2);
    expect(changes, [2]);

    blockPagePop.value = false;
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('起始页'), findsOneWidget);
  });

  testWidgets('长列表搜索、清空、禁用项不可提交，以及禁用/加载/空列表状态', (tester) async {
    final selected = ValueNotifier<int?>(1);
    addTearDown(selected.dispose);
    final changes = <int>[];
    await tester.pumpWidget(
      _host(_controlled(selected, _buildings(), label: '楼栋', changes: changes)),
    );
    await _open(tester);
    expect(_searchField(), findsOneWidget);

    await tester.enterText(_searchField(), '不存在的楼栋');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的选项'), findsOneWidget);
    await tester.tap(find.byTooltip('清空搜索'));
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的选项'), findsNothing);

    await tester.enterText(_searchField(), '楼栋 4');
    await tester.pumpAndSettle();
    await tester.tap(find.text('楼栋 4').last);
    await tester.pumpAndSettle();
    expect(changes, isEmpty);

    await tester.enterText(_searchField(), '  楼栋 8  ');
    await tester.pumpAndSettle();
    await tester.tap(find.text('楼栋 8').last);
    await tester.pumpAndSettle();
    expect(selected.value, 8);
    expect(changes, [8]);

    final blockedChanges = <int>[];
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
              onChanged: blockedChanges.add,
            ),
            AppSelectField<int>(
              key: const Key('loading'),
              label: '房间',
              options: _terms,
              loading: true,
              onChanged: blockedChanges.add,
            ),
            AppSelectField<int>(
              key: const Key('empty'),
              label: '学期',
              hint: '暂无数据',
              options: const [],
              onChanged: blockedChanges.add,
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
    expect(blockedChanges, isEmpty);
  });

  testWidgets('表单校验保存重置与深色模式键盘选择', (tester) async {
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

    await _open(tester);
    await tester.tap(find.text('第二学期'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存表单'));
    await tester.pumpAndSettle();
    expect(saved, 2);

    await tester.tap(find.text('重置表单'));
    await tester.pumpAndSettle();
    expect(find.text('第二学期'), findsNothing);
    expect(find.text('请选择'), findsOneWidget);

    final selected = ValueNotifier<int?>(1);
    addTearDown(selected.dispose);
    await tester.pumpWidget(_host(_controlled(selected, _terms), dark: true));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected.value, 2);
  });
}
