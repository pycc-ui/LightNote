import 'package:uuid/uuid.dart';

import '../../../core/db/app_database.dart';
import '../../../core/util/ai_limits.dart';

/// 笔记库仓储。
///
/// **笔记库是平铺的，没有层级。**
///
/// 它原先叫「目录仓储」，用 `parentId` 存层级、展示时在内存里组树。
/// 改成「笔记库」语义时把层级一并去掉了——当初选 SQLite 而不是文件系统，
/// 本来就是为了不模仿目录树；再长出子笔记库等于把文件系统的复杂性搬回来。
///
/// 所以这里不再有 `buildTree` / `NotebookWithCount`：一个笔记库就是一行，
/// 列表直接渲染即可。删掉树逻辑的附带好处是不再需要
/// "删父笔记库时子笔记库上浮"这类边界处理（那是最容易出错的地方）。
class NotebookRepository {
  NotebookRepository(this._db);

  final AppDatabase _db;
  final _uuid = const Uuid();

  Stream<List<Notebook>> watchAll() => _db.watchNotebooks();

  Future<List<Notebook>> all() => _db.allNotebooks();

  Future<Notebook?> byId(String id) => _db.getNotebook(id);

  Future<int> noteCount(String notebookId) => _db.notebookNoteCount(notebookId);

  Future<Notebook> create({String name = '新笔记库'}) async {
    final now = DateTime.now().toUtc();
    final id = _uuid.v4();
    await _db.upsertNotebook(NotebooksCompanion.insert(
      id: id,
      name: _cleanName(name),
      createdAt: now,
      updatedAt: now,
    ));
    return (await _db.getNotebook(id))!;
  }

  Future<void> rename(String id, String name) async {
    if (name.trim().isEmpty) return;
    await _db.renameNotebook(id, _cleanName(name));
  }

  /// 笔记库名的**唯一收口处**：界面（新建/重命名）与 AI 的
  /// `createNotebook` / `renameNotebook` 都走上面两个方法，所以上限只写一次。
  ///
  /// 上限与"标题"共用 [AiLimits.titleHardMax]：这类**单行短字段**会进 prompt、
  /// 也要上界面，几百字的"名字"没有意义，只会把界面撑坏。
  /// （笔记库名原先没有任何上限。）
  static String _cleanName(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return '新笔记库';
    return t.length > AiLimits.titleHardMax
        ? safeTruncate(t, AiLimits.titleHardMax)
        : t;
  }

  /// 删除笔记库。里面的笔记会回到「我的轻笔记」，不会跟着被删。
  Future<void> softDelete(String id) => _db.softDeleteNotebook(id);
}

/// 一个笔记库 + 它的笔记数，用于列表展示。
///
/// 取代原先的 `NotebookWithCount`（带 depth / children）：没有层级之后
/// 不需要树结构，"笔记库 + 计数"就是全部所需信息。
class NotebookWithCount {
  const NotebookWithCount({required this.notebook, required this.noteCount});

  final Notebook notebook;
  final int noteCount;
}
