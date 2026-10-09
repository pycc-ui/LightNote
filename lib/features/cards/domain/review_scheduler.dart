/// 复习评分四档，映射到 SM-2 的 quality。
///
/// 故意只给四档：五档以上用户分不清"困难"和"有点难"的区别，
/// 反而增加每次复习的决策成本。
enum ReviewGrade {
  forgot(1, '忘记了'),
  hard(3, '有点难'),
  good(4, '记得'),
  easy(5, '太简单');

  const ReviewGrade(this.quality, this.label);

  final int quality;
  final String label;

  /// SM-2 第 1、2 次答对使用固定间隔
  static const firstInterval = 1;
  static const secondInterval = 6;

  /// EF 上下限。下限 1.3 是 SM-2 经典值；
  /// 上限 2.8 是刻意加的：否则长期记忆好的用户会拿到离谱的长间隔
  /// （例如 3 年后），在笔记类应用里没有实际意义。
  static const minEase = 1.3;
  static const maxEase = 2.8;

  /// SM-2 难度因子更新公式：
  ///   EF' = EF + (0.1 - (5-q) * (0.08 + (5-q) * 0.02))
  double nextEase(double currentEase) {
    final q = quality;
    final delta = 0.1 - (5 - q) * (0.08 + (5 - q) * 0.02);
    return (currentEase + delta).clamp(minEase, maxEase);
  }
}

/// 一次复习的调度结算结果（纯数据，可直接写库或单测断言）。
class ScheduleResult {
  const ScheduleResult({
    required this.dueAt,
    required this.intervalDays,
    required this.ease,
    required this.repetitions,
    required this.lapses,
  });

  final DateTime dueAt;
  final int intervalDays;
  final double ease;
  final int repetitions;
  final int lapses;

  @override
  String toString() => 'ScheduleResult(interval: $intervalDays, ease: '
      '${ease.toStringAsFixed(2)}, reps: $repetitions, lapses: $lapses)';
}

/// SM-2 间隔重复调度器。
///
/// 设计成**纯函数**（无 IO、无时钟依赖之外的状态），这样可以直接单测：
/// 见 test/review_scheduler_test.dart。
class ReviewScheduler {
  const ReviewScheduler();

  /// 根据当前状态与评分，算出下一次复习时间与新的调度参数。
  ///
  /// [now] 可注入，便于测试；默认取当前 UTC 时间。
  ScheduleResult schedule({
    required ReviewGrade grade,
    required double ease,
    required int intervalDays,
    required int repetitions,
    required int lapses,
    DateTime? now,
  }) {
    final base = now ?? DateTime.now().toUtc();
    final newEase = grade.nextEase(ease);

    // 答错（quality < 3）：重置连续答对次数，间隔回到 1 天。
    // 注意 EF 已经在 nextEase 里被调低了，这是 SM-2 的标准行为。
    if (grade.quality < 3) {
      return ScheduleResult(
        dueAt: base.add(const Duration(days: ReviewGrade.firstInterval)),
        intervalDays: ReviewGrade.firstInterval,
        ease: newEase,
        repetitions: 0,
        lapses: lapses + 1,
      );
    }

    final newReps = repetitions + 1;
    final int newInterval;

    if (newReps == 1) {
      newInterval = ReviewGrade.firstInterval;
    } else if (newReps == 2) {
      newInterval = ReviewGrade.secondInterval;
    } else {
      // 从第 3 次答对起按 EF 增长
      newInterval = (intervalDays * newEase).round().clamp(1, 3650);
    }

    return ScheduleResult(
      // 到期时间定在当天同一时刻而不是"当天 0 点"，
      // 这样复习节奏不会因为当天什么时候复习而漂移。
      dueAt: base.add(Duration(days: newInterval)),
      intervalDays: newInterval,
      ease: newEase,
      repetitions: newReps,
      lapses: lapses,
    );
  }
}
