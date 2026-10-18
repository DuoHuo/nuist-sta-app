import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_perf.dart';

void main() {
  setUp(TimetablePerf.resetForTest);

  test('mark without start is a safe no-op', () {
    expect(TimetablePerf.armed, isFalse);
    expect(TimetablePerf.markGridFirstFrame(courses: 3), isNull);
  });

  test('fires only once per start', () {
    TimetablePerf.start();
    expect(TimetablePerf.armed, isTrue);
    final ms = TimetablePerf.markGridFirstFrame(courses: 5);
    expect(ms, isNotNull);
    expect(ms, greaterThanOrEqualTo(0));
    expect(TimetablePerf.armed, isFalse);
    expect(TimetablePerf.markGridFirstFrame(courses: 5), isNull);
  });

  test('re-arms on next start (new page open)', () {
    TimetablePerf.start();
    TimetablePerf.markGridFirstFrame(courses: 1);
    TimetablePerf.start();
    expect(TimetablePerf.markGridFirstFrame(courses: 1), isNotNull);
  });
}
