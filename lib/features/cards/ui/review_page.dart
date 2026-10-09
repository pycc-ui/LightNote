import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/util/text_utils.dart';
import '../domain/card_repository.dart';
import '../domain/review_scheduler.dart';

// Drift 从 `cards` 表生成了一个名为 `Card` 的类，与 Flutter 的 Card 组件同名。
// 本文件两者都要用，而 material.dart 无法单独 hide，所以用**导入别名**区分：
//   Card    -> Flutter 的 Card 组件
//   db.Card -> Drift 的卡片数据行
import '../../../core/db/app_database.dart' as db;

/// 复习页：今日待复习队列 + SM-2 四档评分。
class ReviewPage extends StatefulWidget {
  const ReviewPage({super.key});

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  bool _revealed = false;
  Stopwatch _stopwatch = Stopwatch();
  ScheduleResult? _lastResult;
  ReviewGrade? _lastGrade;
  String? _currentCardId;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<CardRepository>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('复习'),
        actions: [
          IconButton(
            tooltip: '刷新队列',
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() {}),
          ),
        ],
      ),
      body: StreamBuilder<List<db.Card>>(
        stream: repo.watchDue(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('加载失败：${snapshot.error}'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final cards = snapshot.data!;
          if (cards.isEmpty) {
            return const _AllDoneView();
          }

          final card = cards.first;

          // 换卡时重置翻面状态与计时器
          if (_currentCardId != card.id) {
            _currentCardId = card.id;
            _revealed = false;
            _lastResult = null;
            _lastGrade = null;
            _stopwatch = Stopwatch()..start();
          }

          return Column(
            children: [
              _ProgressBar(remaining: cards.length),
              if (_lastResult != null && _lastGrade != null)
                _ResultBanner(grade: _lastGrade!, result: _lastResult!),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _FaceCard(
                        label: '问题',
                        text: card.question,
                        emphasized: true,
                      ),
                      if (_revealed) ...[
                        const SizedBox(height: 16),
                        _FaceCard(label: '答案', text: card.answer),
                      ],
                      if (!_revealed) ...[
                        const SizedBox(height: 24),
                        FilledButton.tonal(
                          onPressed: () => setState(() => _revealed = true),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          child: const Text('显示答案'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (_revealed)
                _GradeBar(
                  ease: card.ease,
                  intervalDays: card.intervalDays,
                  repetitions: card.repetitions,
                  onGrade: (grade) => _submit(repo, card, grade),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _submit(
    CardRepository repo,
    db.Card card,
    ReviewGrade grade,
  ) async {
    final elapsed = _stopwatch.elapsedMilliseconds;
    _stopwatch.stop();

    final result = await repo.review(
      card: card,
      grade: grade,
      elapsedMs: elapsed,
    );

    if (!mounted) return;
    setState(() {
      _lastResult = result;
      _lastGrade = grade;
      _currentCardId = null; // 触发下一张卡的状态重置
    });
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.remaining});

  final int remaining;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: Row(
        children: [
          Text(
            '剩余 $remaining 张',
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ],
      ),
    );
  }
}

class _ResultBanner extends StatelessWidget {
  const _ResultBanner({required this.grade, required this.result});

  final ReviewGrade grade;
  final ScheduleResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isForgot = grade.quality < 3;
    return Container(
      width: double.infinity,
      color: isForgot
          ? theme.colorScheme.errorContainer
          : theme.colorScheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        children: [
          Icon(
            isForgot ? Icons.replay : Icons.check_circle_outline,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isForgot
                  ? '已重置为 1 天后重来（EF 已下调至 ${result.ease.toStringAsFixed(2)}）'
                  : '下次复习：${formatInterval(result.intervalDays)}'
                      '（EF ${result.ease.toStringAsFixed(2)}）',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _FaceCard extends StatelessWidget {
  const _FaceCard({
    required this.label,
    required this.text,
    this.emphasized = false,
  });

  final String label;
  final String text;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: emphasized
            ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45)
            : null,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 10),
          SelectableText(
            text,
            style: theme.textTheme.titleMedium?.copyWith(
              height: 1.6,
              fontWeight: emphasized ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}

/// 四档评分条。按钮上直接显示"这个选择会导致多久后再见"，
/// 让用户对间隔重复机制有直觉，而不是盲点。
class _GradeBar extends StatelessWidget {
  const _GradeBar({
    required this.ease,
    required this.intervalDays,
    required this.repetitions,
    required this.onGrade,
  });

  final double ease;
  final int intervalDays;
  final int repetitions;
  final ValueChanged<ReviewGrade> onGrade;

  /// 预览各档评分对应的下次间隔，与 ReviewScheduler 用同一套公式
  String _preview(ReviewGrade grade) {
    const scheduler = ReviewScheduler();
    final r = scheduler.schedule(
      grade: grade,
      ease: ease,
      intervalDays: intervalDays,
      repetitions: repetitions,
      lapses: 0,
      now: DateTime.now().toUtc(),
    );
    return formatInterval(r.intervalDays);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    Widget button(ReviewGrade grade, Color color) {
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: FilledButton(
            onPressed: () => onGrade(grade),
            style: FilledButton.styleFrom(
              backgroundColor: color,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  grade.label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  _preview(grade),
                  style: const TextStyle(fontSize: 10, height: 1.1),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          children: [
            button(ReviewGrade.forgot, scheme.error),
            button(ReviewGrade.hard, const Color(0xFFE08B3C)),
            button(ReviewGrade.good, const Color(0xFF3D8B5F)),
            button(ReviewGrade.easy, const Color(0xFF3D6BB3)),
          ],
        ),
      ),
    );
  }
}

class _AllDoneView extends StatelessWidget {
  const _AllDoneView();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.emoji_events_outlined,
                size: 56, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text('今天的复习完成了', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '没有到期的卡片。\n可以在笔记里用「生成记忆卡片」补充新卡，\n'
              '新卡会立即进入队列。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
