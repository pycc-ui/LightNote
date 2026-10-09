import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/db/app_database.dart';
import '../../../core/secure/secure_store.dart';
import 'review_scheduler.dart';

/// 卡片仓储：把「复习一次」这件事完整包起来 ——
/// 计算调度 → 事务写入卡片状态与流水 → 返回结果供 UI 提示下一次间隔。
class CardRepository {
  CardRepository(this._db, {ReviewScheduler scheduler = const ReviewScheduler()})
      : _scheduler = scheduler;

  final AppDatabase _db;
  final ReviewScheduler _scheduler;
  final _uuid = const Uuid();

  Stream<List<Card>> watchDue() async* {
    final limit = await SecureStore.readDailyNewCards();
    yield* _db.watchDueCards(newCardLimit: limit);
  }

  Future<int> dueCount() => _db.dueCount();

  Future<List<Card>> cardsOfNote(String noteId) => _db.cardsOfNote(noteId);

  /// 提交一次复习。
  ///
  /// [elapsedMs] 是从卡片展示到用户评分的时间，写进流水，
  /// 将来可以用它识别"秒点"的无效复习。
  Future<ScheduleResult> review({
    required Card card,
    required ReviewGrade grade,
    required int elapsedMs,
  }) async {
    final result = _scheduler.schedule(
      grade: grade,
      ease: card.ease,
      intervalDays: card.intervalDays,
      repetitions: card.repetitions,
      lapses: card.lapses,
    );

    // 卡片状态与复习流水必须同一事务写入，
    // 否则中断会出现「调度变了但没有流水」的不一致。
    await _db.applyReview(
      cardId: card.id,
      easeAfter: result.ease,
      intervalAfter: result.intervalDays,
      repetitionsAfter: result.repetitions,
      lapsesAfter: result.lapses,
      dueAt: result.dueAt,
      quality: grade.quality,
      easeBefore: card.ease,
      intervalBefore: card.intervalDays,
      elapsedMs: elapsedMs,
      reviewId: _uuid.v4(),
    );

    return result;
  }

  /// 手动创建卡片（阅读时选中文字做成卡片走这条路）
  Future<String> createCard({
    required String question,
    required String answer,
    String? noteId,
    List<String> tags = const [],
  }) async {
    final id = _uuid.v4();
    final now = DateTime.now().toUtc();
    await _db.upsertCard(CardsCompanion.insert(
      id: id,
      noteId: Value(noteId),
      question: question,
      answer: answer,
      source: const Value('manual'),
      tags: Value(tags.isEmpty ? null : tags.join(',')),
      dueAt: now,
      createdAt: now,
      updatedAt: now,
    ));
    return id;
  }

  Future<void> setSuspended(String cardId, bool suspended) async {
    await (_db.update(_db.cards)..where((t) => t.id.equals(cardId))).write(
      CardsCompanion(
        suspended: Value(suspended),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  Future<void> softDelete(String cardId) async {
    await (_db.update(_db.cards)..where((t) => t.id.equals(cardId))).write(
      CardsCompanion(
        deletedAt: Value(DateTime.now().toUtc()),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  /// 重置为「新卡」，间隔与 EF 回到初始值。用于卡片内容被修正后重新学。
  Future<void> reset(String cardId) async {
    final now = DateTime.now().toUtc();
    await (_db.update(_db.cards)..where((t) => t.id.equals(cardId))).write(
      CardsCompanion(
        ease: const Value(2.5),
        intervalDays: const Value(0),
        repetitions: const Value(0),
        dueAt: Value(now),
        lastReviewedAt: const Value(null),
        updatedAt: Value(now),
      ),
    );
  }
}
