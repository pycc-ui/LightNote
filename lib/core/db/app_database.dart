import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart';

import 'database_location.dart';
import 'tables.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [
    Folders,
    Notes,
    Tags,
    NoteTags,
    CardDecks,
    Cards,
    Reviews,
    NoteSummaries,
    AiCalls,
    AiConversations,
    AiMessages,
    Settings,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  /// 测试用构造：传入内存库
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => kCurrentSchemaVersion;

  /// 当前数据库文件的绝对路径。
  ///
  /// 由 [_openConnection] 在打开时记下，因此设置页展示的路径
  /// 与实际写入的路径永远是同一个值（不会两处各解析一次而互相矛盾）。
  String get databasePath => _activeDbFile?.path ?? '(尚未打开)';

  /// 导出/切换工作目录时用的**一致性快照**。
  ///
  /// 为什么不用 `File.copy`：SQLite 的默认 journal 模式下，
  /// 最近一次事务的内容可能还在 `-journal` 文件里，
  /// 直接拷主文件可能得到一个**少了最后一次提交**的库，
  /// 更糟的是拷到一半 App 又写了一次，会得到撕裂的文件。
  ///
  /// `VACUUM INTO` 是 SQLite 官方提供的在线备份方式：
  /// 由数据库自己保证一致性，且输出是一个已整理过的完整库。
  /// 目标文件必须不存在，否则 SQLite 会直接报错（这也是我们希望的行为，
  /// 避免静默覆盖用户已有的备份）。
  Future<void> snapshotTo(String targetPath) async {
    final escaped = targetPath.replaceAll("'", "''");
    await customStatement("VACUUM INTO '$escaped'");
  }

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _createIndexes();
        },
        onUpgrade: (m, from, to) async {
          // 迁移规则：只追加，永不修改已发布的版本分支。
          // 每次改表后请执行：
          //   dart run drift_dev schema dump lib/core/db/app_database.dart drift_schemas/
          // 并补一条迁移测试。
          //
          // 本次改动（尚未发布过任何版本，因此仍在 schemaVersion 1 内调整）：
          //   notes: archived        -> is_inbox
          //   notes: content_format  -> source（默认值 markdown -> local）
          //   notes: 新增 folder_id
          //   新增: folders / ai_conversations / ai_messages / settings
          //
          // 一旦对外发布，改动必须新增版本号，不能改写这里。
        },
        beforeOpen: (details) async {
          // 外键约束在 SQLite 中默认关闭，必须显式打开，否则 CASCADE/SET NULL 不生效。
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  Future<void> _createIndexes() async {
    // 列表页默认排序
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_notes_updated ON notes(updated_at DESC)',
    );
    // 轻笔记页（收件箱）的主力索引
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_notes_inbox ON notes(is_inbox, updated_at DESC)',
    );
    // 目录详情页
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_notes_folder ON notes(folder_id, updated_at DESC)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_notes_deleted ON notes(deleted_at)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_folders_parent ON folders(parent_id, sort_order)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_cards_due ON cards(suspended, due_at)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_cards_note ON cards(note_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_reviews_card ON reviews(card_id, reviewed_at DESC)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_summaries_note ON note_summaries(note_id, created_at DESC)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_ai_messages_conv ON ai_messages(conversation_id, created_at)',
    );
  }

  // ==========================================================================
  // folders 目录
  // ==========================================================================

  /// 全部未删除目录，按 (层级, 排序, 名称) 排序。
  /// 目录数量通常很少（几十个），一次读全量在内存里组树比递归查询简单可靠。
  Stream<List<Folder>> watchFolders() {
    return (select(folders)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([
            (t) => OrderingTerm(expression: t.sortOrder),
            (t) => OrderingTerm(expression: t.name),
          ]))
        .watch();
  }

  Future<List<Folder>> allFolders() {
    return (select(folders)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([
            (t) => OrderingTerm(expression: t.sortOrder),
            (t) => OrderingTerm(expression: t.name),
          ]))
        .get();
  }

  Future<Folder?> getFolder(String id) {
    return (select(folders)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  Future<int> folderNoteCount(String folderId) async {
    final expr = notes.id.count();
    final q = selectOnly(notes)
      ..addColumns([expr])
      ..where(notes.folderId.equals(folderId) & notes.deletedAt.isNull());
    final row = await q.getSingle();
    return row.read(expr) ?? 0;
  }

  Future<void> upsertFolder(FoldersCompanion entry) {
    return into(folders).insertOnConflictUpdate(entry);
  }

  /// 目录重命名
  Future<void> renameFolder(String id, String name) {
    return (update(folders)..where((t) => t.id.equals(id))).write(
      FoldersCompanion(
        name: Value(name.trim()),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  /// 删除目录（逻辑删除）。
  ///
  /// 关键行为：**目录里的笔记不删**，而是回到轻笔记（收件箱），
  /// 由用户决定去处。直接连笔记一起删掉是数据丢失事故。
  /// 外键的 SET NULL 会把 folder_id 置空，这里再补上 is_inbox = true。
  Future<void> softDeleteFolder(String id) {
    return transaction(() async {
      await (update(notes)
            ..where((t) => t.folderId.equals(id) & t.deletedAt.isNull()))
          .write(
        NotesCompanion(
          folderId: const Value(null),
          isInbox: const Value(true),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
      // 子目录上浮为顶层，避免出现指向已删除目录的孤儿
      await (update(folders)..where((t) => t.parentId.equals(id))).write(
        FoldersCompanion(
          parentId: const Value(null),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
      await (update(folders)..where((t) => t.id.equals(id))).write(
        FoldersCompanion(deletedAt: Value(DateTime.now().toUtc())),
      );
    });
  }

  // ==========================================================================
  // notes
  // ==========================================================================

  /// 轻笔记页：收件箱里的速记，最新在前。
  Stream<List<Note>> watchInboxNotes() {
    return (select(notes)
          ..where((t) =>
              t.deletedAt.isNull() &
              t.isInbox.equals(true) &
              t.folderId.isNull())
          ..orderBy([
            (t) => OrderingTerm(expression: t.pinned, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  /// 笔记库「最近笔记」：已归档的全部笔记
  Stream<List<Note>> watchLibraryNotes() {
    return (select(notes)
          ..where((t) => t.deletedAt.isNull() & t.isInbox.equals(false))
          ..orderBy([
            (t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  /// 目录详情页：该目录内的笔记
  Stream<List<Note>> watchNotesInFolder(String folderId) {
    return (select(notes)
          ..where((t) => t.deletedAt.isNull() & t.folderId.equals(folderId))
          ..orderBy([
            (t) => OrderingTerm(expression: t.pinned, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  /// 兼容：全部未删除笔记（不含轻笔记与已归档的区分）
  Stream<List<Note>> watchNotes() {
    return (select(notes)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([
            (t) => OrderingTerm(expression: t.pinned, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  Future<List<Note>> allActiveNotes() {
    return (select(notes)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([
            (t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc),
          ]))
        .get();
  }

  Stream<Note?> watchNote(String id) {
    return (select(notes)..where((t) => t.id.equals(id))).watchSingleOrNull();
  }

  Future<Note?> getNote(String id) {
    return (select(notes)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// 搜索：标题或正文命中。
  ///
  /// 首版用 LIKE。中文全文检索需要 FTS5 + trigram/jieba 分词，列入 v1.1。
  ///
  /// 转义说明：`%` 与 `_` 在 LIKE 里是通配符，用户输入含这两个字符时若不转义，
  /// 搜 "100%" 会变成匹配任意串。SQLite 的 ESCAPE 子句要求显式给出转义符，
  /// 这里用反斜杠。
  ///
  /// 反斜杠用 [String.fromCharCode] 构造，而不是写成「r 前缀 + 单引号 + 反斜杠」：
  /// Dart 的 raw 字符串不能以反斜杠结尾（反斜杠会转义收尾引号），
  /// 那种写法是语法错误。这里是构建期求值，运行期零开销。
  static final _backslash = String.fromCharCode(0x5C);

  Stream<List<Note>> searchNotes(String keyword) {
    final escaped = keyword
        .trim()
        .replaceAll(_backslash, '$_backslash$_backslash')
        .replaceAll('%', '$_backslash%')
        .replaceAll('_', '${_backslash}_');
    final k = '%$escaped%';
    return (select(notes)
          ..where((t) =>
              t.deletedAt.isNull() &
              (t.title.like(k, escapeChar: _backslash) |
                  t.content.like(k, escapeChar: _backslash)))
          ..orderBy([
            (t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  Future<void> upsertNote(NotesCompanion entry) {
    return into(notes).insertOnConflictUpdate(entry);
  }

  /// 逻辑删除：保留数据，可做回收站与增量同步
  Future<void> softDeleteNote(String id) {
    return (update(notes)..where((t) => t.id.equals(id))).write(
      NotesCompanion(
        deletedAt: Value(DateTime.now().toUtc()),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  Future<void> setPinned(String id, bool pinned) {
    return (update(notes)..where((t) => t.id.equals(id))).write(
      NotesCompanion(
        pinned: Value(pinned),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  /// 轻笔记 → 笔记库：指定目录即完成归档。
  /// 传 null 表示「移出目录，回到轻笔记」。
  Future<void> moveNoteToFolder(String noteId, String? folderId) {
    return (update(notes)..where((t) => t.id.equals(noteId))).write(
      NotesCompanion(
        folderId: Value(folderId),
        isInbox: Value(folderId == null),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  Future<void> saveReadingProgress(String id, double progress, int seconds) {
    return (update(notes)..where((t) => t.id.equals(id))).write(
      NotesCompanion(
        readingProgress: Value(progress.clamp(0.0, 1.0)),
        readingSeconds: Value(seconds),
      ),
    );
  }

  // ==========================================================================
  // tags
  // ==========================================================================

  /// 按 normalizedName 复用已有标签，不存在才新建。返回 tagId。
  Future<String> ensureTag(String tagId, String name) async {
    final normalized =
        name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty) {
      throw ArgumentError('标签名不能为空');
    }
    final existing = await (select(tags)
          ..where((t) => t.normalizedName.equals(normalized)))
        .getSingleOrNull();
    if (existing != null) return existing.id;

    await into(tags).insert(
      TagsCompanion.insert(
        id: tagId,
        name: name.trim(),
        normalizedName: normalized,
        createdAt: DateTime.now().toUtc(),
      ),
    );
    return tagId;
  }

  Future<void> attachTag(String noteId, String tagId) async {
    // 不能用 insert 的返回值判断"是否真的插入了"：
    // 即使 InsertMode.insertOrIgnore 因复合主键冲突而忽略，返回的也是
    // **尝试写入的行数 1**，不是实际插入行数。用它做条件会让 usageCount
    // 在重复关联时被反复累加（真实 bug，已被测试抓出）。
    // 因此先显式查一次存在性。
    final already = await (select(noteTags)
          ..where((t) => t.noteId.equals(noteId) & t.tagId.equals(tagId))
          ..limit(1))
        .getSingleOrNull();
    if (already != null) return;

    await into(noteTags).insert(
      NoteTagsCompanion.insert(
        noteId: noteId,
        tagId: tagId,
        createdAt: DateTime.now().toUtc(),
      ),
      mode: InsertMode.insertOrIgnore,
    );
    await customStatement(
      'UPDATE tags SET usage_count = usage_count + 1 WHERE id = ?',
      [tagId],
    );
  }

  Future<void> detachTag(String noteId, String tagId) async {
    final n = await (delete(noteTags)
          ..where((t) => t.noteId.equals(noteId) & t.tagId.equals(tagId)))
        .go();
    if (n > 0) {
      await customStatement(
        'UPDATE tags SET usage_count = MAX(usage_count - 1, 0) WHERE id = ?',
        [tagId],
      );
    }
  }

  Stream<List<Tag>> watchTags() {
    return (select(tags)
          ..orderBy([
            (t) => OrderingTerm(expression: t.usageCount, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.name),
          ]))
        .watch();
  }

  Future<List<Tag>> tagsOfNote(String noteId) {
    final query = select(tags).join([
      innerJoin(noteTags, noteTags.tagId.equalsExp(tags.id)),
    ])
      ..where(noteTags.noteId.equals(noteId));
    return query.map((row) => row.readTable(tags)).get();
  }

  // ==========================================================================
  // cards
  // ==========================================================================

  /// 今日待复习：到期的旧卡 + 限量新卡。
  ///
  /// 新卡限量在 Dart 层做，避免 SQL 里写窗口函数导致难维护。
  Stream<List<Card>> watchDueCards({int newCardLimit = 15}) {
    final endOfToday = _endOfTodayUtc();
    return (select(cards)
          ..where((t) =>
              t.suspended.equals(false) &
              t.deletedAt.isNull() &
              t.dueAt.isSmallerOrEqualValue(endOfToday))
          ..orderBy([(t) => OrderingTerm(expression: t.dueAt)]))
        .watch()
        .map((rows) {
      final dueReviews = <Card>[];
      final fresh = <Card>[];
      for (final c in rows) {
        if (c.repetitions == 0) {
          fresh.add(c);
        } else {
          dueReviews.add(c);
        }
      }
      fresh.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return [...dueReviews, ...fresh.take(newCardLimit)];
    });
  }

  Future<int> dueCount() async {
    final endOfToday = _endOfTodayUtc();
    final expr = cards.id.count();
    final q = selectOnly(cards)
      ..addColumns([expr])
      ..where(cards.suspended.equals(false) &
          cards.deletedAt.isNull() &
          cards.dueAt.isSmallerOrEqualValue(endOfToday));
    final row = await q.getSingle();
    return row.read(expr) ?? 0;
  }

  Future<List<Card>> cardsOfNote(String noteId) {
    return (select(cards)
          ..where((t) => t.noteId.equals(noteId) & t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm(expression: t.createdAt)]))
        .get();
  }

  Future<void> upsertCard(CardsCompanion entry) {
    return into(cards).insertOnConflictUpdate(entry);
  }

  /// 复习一次：写调度状态 + 追加一条流水。
  ///
  /// 两件事必须在同一个事务里，否则中断会出现「调度变了但没有流水」的不一致。
  Future<void> applyReview({
    required String cardId,
    required double easeAfter,
    required int intervalAfter,
    required int repetitionsAfter,
    required int lapsesAfter,
    required DateTime dueAt,
    required int quality,
    required double easeBefore,
    required int intervalBefore,
    required int elapsedMs,
    required String reviewId,
  }) {
    return transaction(() async {
      await (update(cards)..where((t) => t.id.equals(cardId))).write(
        CardsCompanion(
          ease: Value(easeAfter),
          intervalDays: Value(intervalAfter),
          repetitions: Value(repetitionsAfter),
          lapses: Value(lapsesAfter),
          dueAt: Value(dueAt),
          lastReviewedAt: Value(DateTime.now().toUtc()),
          updatedAt: Value(DateTime.now().toUtc()),
          reviewCount: Value(await _reviewCountPlusOne(cardId)),
        ),
      );
      await into(reviews).insert(
        ReviewsCompanion.insert(
          id: reviewId,
          cardId: cardId,
          quality: quality,
          easeBefore: easeBefore,
          easeAfter: easeAfter,
          intervalBefore: intervalBefore,
          intervalAfter: intervalAfter,
          elapsedMs: Value(elapsedMs),
          reviewedAt: DateTime.now().toUtc(),
        ),
      );
    });
  }

  Future<int> _reviewCountPlusOne(String cardId) async {
    final c = await (select(cards)..where((t) => t.id.equals(cardId)))
        .getSingleOrNull();
    return (c?.reviewCount ?? 0) + 1;
  }

  // ==========================================================================
  // AI 结果与审计
  // ==========================================================================

  Future<void> insertSummary(NoteSummariesCompanion entry) {
    return into(noteSummaries).insert(entry);
  }

  /// 笔记最近一次 AI 整理结果
  Stream<NoteSummary?> watchLatestSummary(String noteId) {
    return (select(noteSummaries)
          ..where((t) => t.noteId.equals(noteId))
          ..orderBy([
            (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
          ])
          ..limit(1))
        .watchSingleOrNull();
  }

  Future<void> markNoteAiDone(String noteId) {
    return (update(notes)..where((t) => t.id.equals(noteId))).write(
      NotesCompanion(lastAiAt: Value(DateTime.now().toUtc())),
    );
  }

  Future<void> insertAiCall(AiCallsCompanion entry) {
    return into(aiCalls).insert(entry);
  }

  /// 设置页展示累计成本（分）
  Stream<double> watchTotalCostCents() {
    final total = aiCalls.costCents.sum();
    return (selectOnly(aiCalls)..addColumns([total]))
        .watchSingle()
        .map((row) => row.read(total) ?? 0.0);
  }

  Future<void> clearAiHistory() {
    return transaction(() async {
      await delete(aiCalls).go();
      await delete(noteSummaries).go();
    });
  }

  // ==========================================================================
  // AI 会话（设计稿 §6.3）
  // ==========================================================================

  Stream<List<AiConversation>> watchConversations() {
    return (select(aiConversations)
          ..orderBy([
            (t) => OrderingTerm(
                expression: t.updatedAt, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  Future<AiConversation?> getConversation(String id) {
    return (select(aiConversations)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  Stream<List<AiMessage>> watchMessages(String conversationId) {
    return (select(aiMessages)
          ..where((t) => t.conversationId.equals(conversationId))
          ..orderBy([(t) => OrderingTerm(expression: t.createdAt)]))
        .watch();
  }

  Future<void> upsertConversation(AiConversationsCompanion entry) {
    return into(aiConversations).insertOnConflictUpdate(entry);
  }

  Future<void> touchConversation(String id, {String? title}) {
    return (update(aiConversations)..where((t) => t.id.equals(id))).write(
      AiConversationsCompanion(
        updatedAt: Value(DateTime.now().toUtc()),
        title: title == null ? const Value.absent() : Value(title),
      ),
    );
  }

  Future<void> deleteConversation(String id) {
    return (delete(aiConversations)..where((t) => t.id.equals(id))).go();
  }

  Future<void> insertAiMessage(AiMessagesCompanion entry) {
    return into(aiMessages).insert(entry);
  }

  Future<void> updateAiMessage(String id, String content) {
    return (update(aiMessages)..where((t) => t.id.equals(id))).write(
      AiMessagesCompanion(content: Value(content)),
    );
  }

  // ==========================================================================
  // settings（key-value）
  // ==========================================================================

  Future<String?> readSetting(String key) async {
    final row = await (select(settings)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Stream<String?> watchSetting(String key) {
    return (select(settings)..where((t) => t.key.equals(key)))
        .watchSingleOrNull()
        .map((row) => row?.value);
  }

  Future<void> writeSetting(String key, String value) {
    return into(settings).insertOnConflictUpdate(
      SettingsCompanion.insert(key: key, value: value),
    );
  }

  Future<void> deleteSetting(String key) {
    return (delete(settings)..where((t) => t.key.equals(key))).go();
  }

  static DateTime _endOfTodayUtc() {
    final now = DateTime.now();
    final endLocal = DateTime(now.year, now.month, now.day, 23, 59, 59);
    return endLocal.toUtc();
  }
}

/// 当前数据库文件。
///
/// 顶层变量而不是 `AppDatabase` 的静态字段：写它的是 [_openConnection]
/// （一个顶层函数），读它的是 `AppDatabase.databasePath`。
/// 放在顶层，两边引用的是同一个东西。
File? _activeDbFile;

/// 打开数据库连接。
///
/// 关键点：用 `NativeDatabase`（基于 dart:ffi）而不是 `SqfliteQueryExecutor`，
/// 这样 **同一份代码同时跑 Android 和 Windows 桌面调试**，无需条件分支。
/// 自 drift 2.32 / sqlite3 3.x 起，SQLite 原生库由 build hooks 自动打包，
/// 不再需要依赖 `sqlite3_flutter_libs`。
///
/// 目录解析交给 [DatabaseLocation]：
/// **默认放 App 私有目录**，用户可以在设置里改成自己的工作目录。
/// 这里只负责拿目录、记录实际路径、开连接。
LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await DatabaseLocation.resolveDirectory();

    // Android 上系统临时目录对 SQLite 不可用，复杂查询会 OOM。
    // 官方文档明确要求：打开数据库前告知临时目录位置。
    if (Platform.isAndroid) {
      try {
        final tmp = Directory.systemTemp;
        if (tmp.existsSync()) sqlite3.tempDirectory = tmp.path;
      } catch (_) {
        // 拿不到临时目录不致命：SQLite 会退回系统默认值，
        // 极端复杂查询才可能受影响，不值得让 App 起不来。
      }
    }

    final file = File(DatabaseLocation.dbPathIn(dir));
    _activeDbFile = file;

    final note = DatabaseLocation.lastFallbackNote;
    if (note != null) {
      // 发生降级必须留下痕迹：用户以为数据在新位置、实际还在私有目录，
      // 这是最容易导致"我的笔记不见了"的一类问题。
      // ignore: avoid_print
      print('[LightNote] 数据库位置降级：$note\n  实际使用：${file.path}');
    }

    // 不在这里设 PRAGMA journal_mode=WAL：WAL 是持久化设置，
    // 而切换 journal mode 需要独占锁，放在每次连接都会跑的 setup 回调里
    // 可能与并发连接冲突。默认的 rollback journal 对本 App 的读写量足够。
    return NativeDatabase.createInBackground(file);
  });
}
