import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/db/app_database.dart';
import '../../ai/data/rag_index_schedule.dart';
import '../../../core/util/text_utils.dart';
import 'note_chunk_repository.dart';

/// 笔记仓储：所有写操作集中在这里，保证 updatedAt / excerpt / wordCount
/// 这些派生字段不会因为某个页面忘了更新而产生不一致。
///
/// 「轻笔记」与「笔记库」是同一张表的两种视图，靠 `isInbox` 与 `notebookId` 区分：
///   轻笔记：isInbox = true 且 notebookId 为空
///   笔记库：isInbox = false（已归档），可归属某个笔记库
///
/// ## 派生字段的口径只有一处实现
///
/// `excerpt` / `wordCount` 走 [TextUtils]（`core/util/text_utils.dart`）。
/// 不要再抄一份私有实现，理由"core 层不该反向依赖 feature 层"读错了依赖方向：
/// `text_utils` 就在 `core/util/`，`features/ → core/` 正是允许的方向。
/// 口径不一致的话，同一篇笔记由页面写和由 AI 写，字数与预览会不一样。
class NoteRepository {
  NoteRepository(this._db) : _chunks = NoteChunkRepository(_db);

  final AppDatabase _db;

  /// 自己造一个（而不是从外面注入）：它和本仓储共用同一个 db，
  /// 多一个构造参数就要改 `main.dart` 的 Provider 和一堆测试调用点，
  /// 换不来任何好处。
  final NoteChunkRepository _chunks;
  final _uuid = const Uuid();

  // ---- 读 ----

  /// 轻笔记页（收件箱）
  Stream<List<Note>> watchInbox() => _db.watchInboxNotes();

  /// 未归档笔记（笔记库页的「轻笔记」区块）
  Stream<List<Note>> watchUnfiled() => _db.watchUnfiledNotes();

  /// 某笔记库下的笔记
  Stream<List<Note>> watchNotesInNotebook(String notebookId) =>
      _db.watchNotesInNotebook(notebookId);

  /// 全部未删除笔记
  Stream<List<Note>> watchAll() => _db.watchNotes();

  Stream<Note?> watch(String id) => _db.watchNote(id);

  Future<Note?> byId(String id) => _db.getNote(id);

  Future<List<Note>> allActive() => _db.allActiveNotes();

  Stream<List<Note>> search(String keyword) {
    if (keyword.trim().isEmpty) return _db.watchNotes();
    return _db.searchNotes(keyword);
  }

  /// **限定在某个笔记库内**搜索（笔记库详情页的搜索图标用）。
  ///
  /// 与 [search] 分开：笔记库页顶栏的搜索是全局的（包含「我的轻笔记」），
  /// 而进了某个笔记库之后再搜，用户预期是"在这个库里找"。
  Stream<List<Note>> searchInNotebook(String notebookId, String keyword) {
    if (keyword.trim().isEmpty) return _db.watchNotesInNotebook(notebookId);
    return _db.searchNotesInNotebook(notebookId, keyword);
  }

  /// 实时搜索结果（Future 版，供需要一次性结果的场景）
  Future<List<Note>> searchOnce(String keyword) async {
    if (keyword.trim().isEmpty) return const [];
    return _db.searchNotes(keyword).first;
  }

  // ---- 写 ----

  /// 新建「轻笔记」（速记）——**未归档**，出现在笔记库页的「轻笔记」区块。
  Future<Note> createInbox({String title = '', String content = ''}) {
    return _create(title: title, content: content, isInbox: true);
  }

  /// 直接在某个笔记库下新建笔记（自动归档）
  Future<Note> createInNotebook(
    String notebookId, {
    String title = '',
    String content = '',
  }) {
    return _create(
      title: title,
      content: content,
      isInbox: false,
      notebookId: notebookId,
    );
  }

  Future<Note> _create({
    required String title,
    required String content,
    required bool isInbox,
    String? notebookId,
  }) async {
    final now = DateTime.now().toUtc();
    final id = _uuid.v4();
    await _db.upsertNote(NotesCompanion.insert(
      id: id,
      title: Value(title),
      content: Value(content),
      notebookId: Value(notebookId),
      isInbox: Value(isInbox),
      excerpt: Value(TextUtils.excerpt(content)),
      wordCount: Value(TextUtils.wordCountOfMarkdown(content)),
      createdAt: now,
      updatedAt: now,
    ));
    return (await _db.getNote(id))!;
  }

  /// 保存正文。派生字段（excerpt / wordCount）在这里统一重算。
  ///
  /// 用 upsert 而不是 update：upsert 内部是 INSERT ... ON CONFLICT DO UPDATE，
  /// 所以必须带齐所有「非空且无默认值」的列（createdAt 就是这种列），
  /// 否则 Drift 会在写库前抛 InvalidDataException。
  /// 这些值从已读出的 existing 行原样带回，语义不变。
  Future<void> saveContent(String id, {String? title, String? content}) async {
    final existing = await _db.getNote(id);
    if (existing == null) return;

    final nextTitle = title ?? existing.title;
    final nextContent = content ?? existing.content;

    await _db.upsertNote(NotesCompanion(
      id: Value(id),
      title: Value(nextTitle),
      content: Value(nextContent),
      excerpt: Value(TextUtils.excerpt(nextContent)),
      wordCount: Value(TextUtils.wordCountOfMarkdown(nextContent)),
      createdAt: Value(existing.createdAt),
      updatedAt: Value(DateTime.now().toUtc()),
      deletedAt: Value(existing.deletedAt),
    ));

    // 切片跟着正文走。**大多数时候这里什么都不做** —— 只有"还没切过"或
    // "长度变化超过 20%"才重切；小改动留给读片时的 hash 自愈
    // （见 `NoteChunkRepository`）。放在 `saveContent` 里是因为它是正文变更的
    // **唯一漏斗**：编辑页（防抖 500ms 后）、导入、AI 写入都走它。
    if (nextContent != existing.content) {
      await _chunks.onNoteSaved(id, nextContent);

      // 语义检索的向量也跟着正文走，但**绝不能在这里等**：嵌入一条要 74ms
      // 纯 CPU（实测），而这条路径是编辑页防抖 500ms 后 await 的 —— 同步等
      // 等于用户每停一次手就多卡一下。交给后台调度，落后几秒没有影响。
      //
      // `instance` 在测试里是 null（没人调 `RagIndexSchedule.start`），
      // 所以测试一行都不会执行到，也不会有"库关了后台还在查库"那种错
      //（`feed_repository` 踩过同一个坑，注释还留着）。
      RagIndexSchedule.instance?.noteChanged(id);
    }
  }

  /// 轻笔记 → 加入笔记库（指定笔记库）
  Future<void> moveToNotebook(String noteId, String notebookId) =>
      _db.moveNoteToNotebook(noteId, notebookId);

  /// 移出笔记库，回到轻笔记
  Future<void> moveToInbox(String noteId) =>
      _db.moveNoteToNotebook(noteId, null);

  /// 逻辑删除 + **清掉切片**。
  ///
  /// ⚠️ 切片表的外键带 `ON DELETE CASCADE`，但项目用的是**软删除**
  /// （`deleted_at` 置位、行还在），级联根本不会触发。软删的笔记若还留着片，
  /// 搜索就会把"命中哪一片"算到已删的笔记头上，用户点进去发现笔记没了。
  ///
  /// 恢复（[restore]）时切片会被按需重建（读路径发现 0 片就现切），
  /// 所以清掉是安全的。
  Future<void> softDelete(String id) async {
    await _db.softDeleteNote(id);
    await _chunks.clearFor(id);
  }

  /// 撤销删除。
  ///
  /// 左滑删除是"乐观删除 + 撤销"（删完在提示条上留一个撤销），
  /// 所以需要恢复入口。逻辑删除让这件事很便宜：清空 `deletedAt` 即可，
  /// 卡片、切片等关联都还在。
  Future<void> restore(String id) => _db.restoreNote(id);

  // ---- 批量操作（多选模式用）----

  /// 批量逻辑删除。
  ///
  /// 放在**一个事务**里：多选删 20 条时，中途失败不该留下删一半的状态
  /// （用户看到"删了 13 条"比"一条没删"更糟——他分不清哪些还在）。
  Future<void> softDeleteMany(Iterable<String> ids) async {
    final list = ids.toList(growable: false);
    if (list.isEmpty) return;
    await _db.transaction(() async {
      for (final id in list) {
        await _db.softDeleteNote(id);
        // 切片一起清（理由同 [softDelete]：软删不触发外键级联）
        await _db.replaceNoteChunks(id, const []);
      }
    });
  }

  /// 批量移动到某个笔记库；[notebookId] 为 null 表示移回「我的轻笔记」。
  ///
  /// 同样是一个事务。返回**实际受影响的条数**，便于提示里说实话
  /// （"已移动 12 条"而不是"已移动"）。
  Future<int> moveManyToNotebook(
    Iterable<String> ids,
    String? notebookId,
  ) async {
    final list = ids.toList(growable: false);
    if (list.isEmpty) return 0;
    await _db.transaction(() async {
      for (final id in list) {
        await _db.moveNoteToNotebook(id, notebookId);
      }
    });
    return list.length;
  }

  Future<void> setPinned(String id, bool pinned) => _db.setPinned(id, pinned);

  /// **按给定顺序重排**（拖动排序、以及"置顶 = 挪到最前"都用它）。
  ///
  /// [idsInOrder] 必须是**当前可见列表的完整顺序**：重编号是从 1 开始的密集
  /// 编号（0 留给"没排过"，见 `AppDatabase.reorderNotes`），所以漏传的笔记
  /// 会掉回"没排过"那一组、跑到最前面去。
  Future<void> reorder(List<String> idsInOrder) =>
      _db.reorderNotes(idsInOrder);

  /// 把一批笔记里的某一篇**挪到最前**，其余保持原相对顺序。
  ///
  /// 置顶就是这么实现的：它只是"这次把它放到第一位"，不是"以后一直压着别人"。
  Future<void> moveToFront(List<String> currentOrder, String id) {
    final rest = [
      for (final x in currentOrder)
        if (x != id) x,
    ];
    return reorder([id, ...rest]);
  }
}
