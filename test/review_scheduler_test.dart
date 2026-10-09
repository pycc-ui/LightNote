import 'package:flutter_test/flutter_test.dart';
import 'package:smart_notes/features/cards/domain/review_scheduler.dart';

/// SM-2 调度器是纯函数，可以完全离线、确定性地测试。
/// 这层是记忆卡片功能里唯一有"数学正确性"要求的部分，必须有测试兜住。
void main() {
  const scheduler = ReviewScheduler();
  final base = DateTime.utc(2026, 3, 1, 10, 0, 0);

  group('新卡（repetitions = 0）', () {
    test('第一次答对：间隔 1 天，EF 不变（good 对应 delta 0）', () {
      final r = scheduler.schedule(
        grade: ReviewGrade.good,
        ease: 2.5,
        intervalDays: 0,
        repetitions: 0,
        lapses: 0,
        now: base,
      );
      expect(r.intervalDays, 1);
      expect(r.repetitions, 1);
      expect(r.ease, closeTo(2.5, 0.0001));
      expect(r.dueAt, base.add(const Duration(days: 1)));
    });

    test('第一次就点"太简单"：间隔仍是 1 天，但 EF 上调', () {
      final r = scheduler.schedule(
        grade: ReviewGrade.easy,
        ease: 2.5,
        intervalDays: 0,
        repetitions: 0,
        lapses: 0,
        now: base,
      );
      // quality=5 → delta = 0.1 - 0*(0.08+0) = 0.1
      expect(r.ease, closeTo(2.6, 0.0001));
      expect(r.intervalDays, 1);
    });

    test('第一次就点"有点难"：EF 下调 0.14', () {
      final r = scheduler.schedule(
        grade: ReviewGrade.hard,
        ease: 2.5,
        intervalDays: 0,
        repetitions: 0,
        lapses: 0,
        now: base,
      );
      // quality=3 → delta = 0.1 - 2*(0.08 + 2*0.02) = 0.1 - 2*0.12 = -0.14
      expect(r.ease, closeTo(2.36, 0.0001));
    });
  });

  group('答错重置', () {
    test('忘记了：间隔回到 1 天、repetitions 归零、lapses +1', () {
      final r = scheduler.schedule(
        grade: ReviewGrade.forgot,
        ease: 2.5,
        intervalDays: 30,
        repetitions: 5,
        lapses: 2,
        now: base,
      );
      expect(r.intervalDays, 1);
      expect(r.repetitions, 0);
      expect(r.lapses, 3);
      expect(r.dueAt, base.add(const Duration(days: 1)));
      // quality=1 → delta = 0.1 - 4*(0.08 + 4*0.02) = 0.1 - 4*0.16 = -0.54
      expect(r.ease, closeTo(1.96, 0.0001));
    });

    test('EF 永远不会低于下限 1.3', () {
      var ease = 1.35;
      for (var i = 0; i < 10; i++) {
        final r = scheduler.schedule(
          grade: ReviewGrade.forgot,
          ease: ease,
          intervalDays: 1,
          repetitions: 0,
          lapses: 0,
          now: base,
        );
        ease = r.ease;
      }
      expect(ease, closeTo(ReviewGrade.minEase, 0.0001));
    });

    test('EF 永远不会高于上限 2.8', () {
      var ease = 2.75;
      for (var i = 0; i < 10; i++) {
        final r = scheduler.schedule(
          grade: ReviewGrade.easy,
          ease: ease,
          intervalDays: 1,
          repetitions: 1,
          lapses: 0,
          now: base,
        );
        ease = r.ease;
      }
      expect(ease, closeTo(ReviewGrade.maxEase, 0.0001));
    });
  });

  group('间隔增长', () {
    test('第二次答对固定为 6 天（SM-2 的经典设定）', () {
      final r = scheduler.schedule(
        grade: ReviewGrade.good,
        ease: 2.5,
        intervalDays: 1,
        repetitions: 1,
        lapses: 0,
        now: base,
      );
      expect(r.intervalDays, 6);
      expect(r.repetitions, 2);
    });

    test('第三次起按 EF 增长：6 天 × 2.5 = 15 天', () {
      final r = scheduler.schedule(
        grade: ReviewGrade.good,
        ease: 2.5,
        intervalDays: 6,
        repetitions: 2,
        lapses: 0,
        now: base,
      );
      expect(r.intervalDays, 15);
      expect(r.repetitions, 3);
    });

    test('间隔永不超过 3650 天上限（防止异常长的数字）', () {
      final r = scheduler.schedule(
        grade: ReviewGrade.easy,
        ease: 2.8,
        intervalDays: 3000,
        repetitions: 20,
        lapses: 0,
        now: base,
      );
      expect(r.intervalDays, lessThanOrEqualTo(3650));
    });

    test('连续 good 复习的间隔单调不减', () {
      var ease = 2.5;
      var interval = 0;
      var reps = 0;
      var previous = 0;
      for (var i = 0; i < 8; i++) {
        final r = scheduler.schedule(
          grade: ReviewGrade.good,
          ease: ease,
          intervalDays: interval,
          repetitions: reps,
          lapses: 0,
          now: base,
        );
        expect(r.intervalDays, greaterThanOrEqualTo(previous));
        previous = r.intervalDays;
        ease = r.ease;
        interval = r.intervalDays;
        reps = r.repetitions;
      }
    });
  });

  group('下一次到期时间', () {
    test('到期时间为「当前时刻 + 间隔」，而不是当天零点', () {
      final now = DateTime.utc(2026, 3, 1, 23, 30, 0);
      final r = scheduler.schedule(
        grade: ReviewGrade.good,
        ease: 2.5,
        intervalDays: 6,
        repetitions: 2,
        lapses: 0,
        now: now,
      );
      expect(r.dueAt.hour, 23);
      expect(r.dueAt.minute, 30);
      expect(r.dueAt.difference(now).inDays, r.intervalDays);
    });
  });
}
