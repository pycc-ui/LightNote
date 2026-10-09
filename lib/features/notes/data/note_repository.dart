import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/db/app_database.dart';

/// 笔记仓储：所有写操作集中在这里，保证 updatedAt / excerpt / wordCount
/// 这些派生字段不会因为某个页面忘了更新而产生不一致。
///
/// 「轻笔记」与「笔记库」是同一张表的两种视图，靠 `isInbox` 与 `folderId` 区分：
///   轻笔记：isInbox = true 且 folderId 为空
///   笔记库：isInbox = false（已归档），可归属某个目录
class NoteRepository {
  NoteRepository(this._db);

  final AppDatabase _db;
  final _uuid = const Uuid();

  // ---- 读 ----

  /// 轻笔记页（收件箱）
  Stream<List<Note>> watchInbox() => _db.watchInboxNotes();

  /// 笔记库「最近笔记」
  Stream<List<Note>> watchLibrary() => _db.watchLibraryNotes();

  /// 某目录下的笔记
  Stream<List<Note>> watchInFolder(String folderId) =>
      _db.watchNotesInFolder(folderId);

  /// 全部未删除笔记
  Stream<List<Note>> watchAll() => _db.watchNotes();

  Stream<Note?> watch(String id) => _db.watchNote(id);

  Future<Note?> byId(String id) => _db.getNote(id);

  Future<List<Note>> allActive() => _db.allActiveNotes();

  Stream<List<Note>> search(String keyword) {
    if (keyword.trim().isEmpty) return _db.watchNotes();
    return _db.searchNotes(keyword);
  }

  /// 实时搜索结果（Future 版，供需要一次性结果的场景）
  Future<List<Note>> searchOnce(String keyword) async {
    if (keyword.trim().isEmpty) return const [];
    return _db.searchNotes(keyword).first;
  }

  // ---- 写 ----

  /// 新建「轻笔记」（速记，进收件箱）
  Future<Note> createInbox({String title = '', String content = ''}) {
    return _create(title: title, content: content, isInbox: true);
  }

  /// 直接在某个目录下新建笔记（自动归档）
  Future<Note> createInFolder(
    String folderId, {
    String title = '',
    String content = '',
  }) {
    return _create(
      title: title,
      content: content,
      isInbox: false,
      folderId: folderId,
    );
  }

  /// 新建已归档但未指定目录的笔记（笔记库「新建笔记」用）
  Future<Note> createLibrary({String title = '', String content = ''}) {
    return _create(title: title, content: content, isInbox: false);
  }

  Future<Note> _create({
    required String title,
    required String content,
    required bool isInbox,
    String? folderId,
  }) async {
    final now = DateTime.now().toUtc();
    final id = _uuid.v4();
    await _db.upsertNote(NotesCompanion.insert(
      id: id,
      title: Value(title),
      content: Value(content),
      folderId: Value(folderId),
      isInbox: Value(isInbox),
      excerpt: Value(_excerpt(content)),
      wordCount: Value(_wordCount(content)),
      createdAt: now,
      updatedAt: now,
    ));
    return (await _db.getNote(id))!;
  }

  /// 保存正文。派生字段（excerpt / wordCount）在这里统一重算。
  ///
  /// 用 upsert 而不是 update：upsert 内部是 INSERT ... ON CONFLICT DO UPDATE，
  /// 所以**必须带齐所有「非空且无默认值」的列**（createdAt 就是这种列），
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
      excerpt: Value(_excerpt(nextContent)),
      wordCount: Value(_wordCount(nextContent)),
      createdAt: Value(existing.createdAt),
      updatedAt: Value(DateTime.now().toUtc()),
      deletedAt: Value(existing.deletedAt),
    ));
  }

  /// 轻笔记 → 加入笔记库（指定目录）
  Future<void> moveToFolder(String noteId, String folderId) =>
      _db.moveNoteToFolder(noteId, folderId);

  /// 移出目录，回到轻笔记
  Future<void> moveToInbox(String noteId) =>
      _db.moveNoteToFolder(noteId, null);

  Future<void> softDelete(String id) => _db.softDeleteNote(id);

  Future<void> setPinned(String id, bool pinned) => _db.setPinned(id, pinned);

  Future<void> saveReadingProgress(String id, double progress, int seconds) =>
      _db.saveReadingProgress(id, progress, seconds);

  // ---- 标签 ----

  Stream<List<Tag>> watchTags() => _db.watchTags();

  Future<List<Tag>> tagsOf(String noteId) => _db.tagsOfNote(noteId);

  Future<void> addTag(String noteId, String name) async {
    final tagId = await _db.ensureTag(_uuid.v4(), name);
    await _db.attachTag(noteId, tagId);
  }

  Future<void> removeTag(String noteId, String tagId) =>
      _db.detachTag(noteId, tagId);

  /// AI 整理得到的摘要（阅读页顶部与编辑页用）
  Stream<NoteSummary?> watchLatestSummary(String noteId) =>
      _db.watchLatestSummary(noteId);
}

// ============================================================================
// 派生字段计算
//
// 这两个函数刻意留在本文件而不是复用 core/util/text_utils.dart：
// text_utils 里的同族函数返回 Color/extension，属于 UI 侧工具；
// 而 core 层（含 app_database）不应该反向依赖 feature 层。
// 纯文本处理就几十行，重复实现比引入反向依赖更干净。
// ============================================================================

final _mdNoise = RegExp(
  r'```[\s\S]*?```' // 代码块
  r'|!\[[^\]]*\]\([^)]*\)' // 图片
  r'|\[([^\]]*)\]\([^)]*\)' // 链接保留文字
  r'|^\s{0,3}#{1,6}\s*' // 标题标记
  r'|[*_~`>|-]+', // 强调/引用/列表符号
  multiLine: true,
);

final _linkPattern = RegExp(r'\[([^\]]*)\]\([^)]*\)');

/// Markdown → 纯文本（用于预览与字数统计）
String _toPlainText(String markdown) {
  final s = markdown.replaceAllMapped(_mdNoise, (m) {
    final link = _linkPattern.firstMatch(m.group(0)!);
    return link?.group(1) ?? '';
  });
  return s.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

String _excerpt(String content, {int max = 200}) {
  final plain = _toPlainText(content).replaceAll('\n', ' ');
  if (plain.length <= max) return plain;
  return '${plain.substring(0, max)}…';
}

/// 中文按字计、英文按词计。
/// 直接按空格切会把整段中文算成 1 个「词」，所以必须分开处理。
int _wordCount(String content) {
  final text = _toPlainText(content);
  final cjk = RegExp(r'[\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]')
      .allMatches(text)
      .length;
  final latin = RegExp(r'[A-Za-z0-9]+')
      .allMatches(
        text.replaceAll(
          RegExp(r'[\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]'),
          ' ',
        ),
      )
      .length;
  return cjk + latin;
}
