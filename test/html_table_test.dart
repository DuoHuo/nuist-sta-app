// core/html_table.dart 的解析测试：样例参照双创学分与劳动教育平台的页面结构
// （已脱敏，学号/姓名/课程信息均为合成数据），覆盖自定义元素 td-data、隐藏列、
// 空表三个已知的坑。

import 'package:flutter_test/flutter_test.dart';

import 'package:nuist_sta_app/core/html_table.dart';

const _summaryQuery = '''
<div class="change-module">
<table id="c_app_page_index_SummaryQuery_table" class="table m-table">
  <thead>
    <tr>
      <th style="width: 20px;" data-responsive-cell-index="1" class="hidden">
        <label class="m-checkbox"><input type="checkbox"><span></span></label>
      </th>
      <th style="min-width:55px;">
        序号
      </th>
      <th>账号</th>
      <th>用户名</th>
      <th>成绩</th>
      <th style="min-width:90px;">
        <div class='c-table-cell-sort active' data-sort-key='XueFenTotalScore'>
          <span class='c-cell-text'>总学分</span>
          <i class='c-cell-sort fa fa-sort-desc'></i>
        </div>
      </th>
    </tr>
  </thead>
  <tbody>
    <tr class="c--tr" id="goto_8ce7">
      <td class="hidden">
        <label class="m-checkbox"><input type="checkbox" data-value="8ce7"><span></span></label>
      </td>
      <td>
        1
      </td>
      <td>
        202500000000
      </td>
      <td>
        示例同学
      </td>
      <td>
        不及格
      </td>
      <td>
        <a class="m-btn btn" href="/XueFen/SummaryQuery/XueFenIndex?id=8ce7&amp;x=1" data-toggle="m-tooltip">
          3
        </a>
      </td>
    </tr>
  </tbody>
</table>
</div>
''';

const _detail = '''
<table id="c_app_page_index_Summary_table" class="table">
  <thead>
    <tr>
      <th>序号</th>
      <th><div class='c-table-cell-sort'><span class='c-cell-text'>项目名称</span><i class='fa'></i></div></th>
      <th><span class='c-cell-text'>实际分值</span></th>
      <th><span class='c-cell-text'>学分申请人</span></th>
      <th><span class='c-cell-text'>状态</span></th>
    </tr>
  </thead>
  <tbody>
    <tr id="goto_6d2e" class="c--tr">
      <td>
        <div class="hidden td-data">
          <td-data data-name='ID' data-value='6d2e'  ></td-data><td-data data-name='ItemName' data-value='程序设计竞赛实验班'  ></td-data>
        </div>
        1
      </td>
      <td>
        <span class="c-link--line c--view-item" data-responsive--bind-click="td>span.c-link--line.c--view-item">
          程序设计竞赛实验班
        </span>
      </td>
      <td>
        1
      </td>
      <td>
        示例同学
        <div>
          <small>(202500000000)</small>
        </div>
      </td>
      <td>
        <span class='m-badge m-badge--success'>学校审核学分通过</span>
      </td>
    </tr>
    <tr id="goto_5a5b" class="c--tr">
      <td><div class="hidden td-data"><td-data data-name='ItemName' data-value='国家英语四级'></td-data></div>2</td>
      <td><span>国家英语四级</span></td>
      <td>1</td>
      <td>示例同学<div><small>(202500000000)</small></div></td>
      <td><span class='m-badge'>学校审核学分通过</span></td>
    </tr>
  </tbody>
</table>
''';

const _studentResult = '''
<table id="ResultManage_StudentResult_Index_table" class="table c-table">
  <thead>
    <tr>
      <th class="text-center cell--checkbox hidden" " data-responsive-cell-index="1"><input type="checkbox" /></th>
      <th class="text-center">序号</th>
      <th><div class='c-table-cell-sort'><span class='c-cell-text'>理论积分</span></div></th>
      <th><div class='c-table-cell-sort'><span class='c-cell-text'>生活劳动</span></div></th>
      <th class="hidden"><div class='c-table-cell-sort'><span class='c-cell-text'>专业劳动</span></div></th>
      <th><div class='c-table-cell-sort'><span class='c-cell-text'>总积分</span></div></th>
      <th>是否确认</th>
      <th><span class='c-cell-text'>更新日期</span></th>
      <th style="min-width:1px;width:1px;">
      </th>
    </tr>
  </thead>
  <tbody>
    <tr id="goto_ea06" class="c--tr" data-table-checkbox-value="ea06">
      <td class="text-center cell--checkbox hidden"><input type="checkbox" disabled /></td>
      <td>
        <div class="hidden td-data">
          <td-data data-name="ID" data-value="ea06"  ></td-data><td-data data-name="UserName" data-value="示例同学"  ></td-data>
        </div>
        1
      </td>
      <td>4</td>
      <td>6</td>
      <td class="hidden">0</td>
      <td>
        <b class="kt-font-success">
          16
        </b>
      </td>
      <td>
        <span class="kt-badge kt-badge--unified-danger">否</span>
      </td>
      <td>
2026-06-30 16:25:27
      </td>
      <td class="c--actions">
        <a class="btn" title="查看变动记录" href="https://labor.campus.invalid/x?UserID=1"><i class="fa fa-info-circle"></i></a>
      </td>
    </tr>
  </tbody>
</table>
''';

const _empty = '''
<table id="ResultManage_ZYLDScoreHZ_Index_table" class="table">
  <thead>
    <tr>
      <th>序号</th>
      <th><span class='c-cell-text'>专业劳动累计积分</span></th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <th colspan="20" class="text-center c-data-empty">
        暂无数据
      </th>
    </tr>
  </tbody>
</table>
''';

void main() {
  test('汇总表：跳过隐藏复选框列，链接里的数字取出来', () {
    final rows = parseHtmlTable(
      _summaryQuery,
      'c_app_page_index_SummaryQuery_table',
    );
    expect(rows, isNotNull);
    expect(rows, hasLength(1));
    final row = rows!.single;
    expect(row['账号'], '202500000000');
    expect(row['用户名'], '示例同学');
    expect(row['成绩'], '不及格');
    expect(row['总学分'], '3');
    // 复选框列表头为空，不该出现在结果里。
    expect(row.containsKey(''), isFalse);
  });

  test('明细表：td-data 自定义元素不被当成单元格，属性里的 > 不截断，多行按序解析', () {
    final rows = parseHtmlTable(_detail, 'c_app_page_index_Summary_table');
    expect(rows, hasLength(2));
    expect(rows![0]['序号'], '1');
    expect(rows[0]['项目名称'], '程序设计竞赛实验班');
    expect(rows[0]['实际分值'], '1');
    expect(rows[0]['学分申请人'], '示例同学 (202500000000)');
    expect(rows[0]['状态'], '学校审核学分通过');
    expect(rows[1]['项目名称'], '国家英语四级');
  });

  test('劳动成绩表：表头里多出的孤立引号不吞列，隐藏列表头与单元格一一对应', () {
    final rows = parseHtmlTable(
      _studentResult,
      'ResultManage_StudentResult_Index_table',
    );
    expect(rows, hasLength(1));
    final row = rows!.single;
    expect(row['理论积分'], '4');
    expect(row['生活劳动'], '6');
    expect(row['专业劳动'], '0');
    expect(row['总积分'], '16');
    expect(row['是否确认'], '否');
    expect(row['更新日期'], '2026-06-30 16:25:27');
  });

  test('空表：「暂无数据」行没有 td，得到空列表而不是 null', () {
    final rows = parseHtmlTable(_empty, 'ResultManage_ZYLDScoreHZ_Index_table');
    expect(rows, isNotNull);
    expect(rows, isEmpty);
  });

  test('找不到目标表格返回 null（用于识别被弹回登录页）', () {
    expect(parseHtmlTable('<html><body>登录</body></html>', 'nope'), isNull);
    expect(parseHtmlTable(_empty, 'c_app_page_index_Summary_table'), isNull);
  });

  test('cleanHtmlText：去标签、解实体、折叠空白', () {
    expect(
      cleanHtmlText('  <b>a</b>&nbsp;&amp;\n\t b &#x2F; &#47; '),
      'a & b / /',
    );
    expect(
      cleanHtmlText('<span data-x="td>span" data-y=\'a>b\'>文本</span>'),
      '文本',
    );
  });
}
