import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/db/app_database.dart';

/// 目录仓储。
///
/// 目录内部用 parentId 存层级，展示时在内存里组成树——目录数量通常只有几十个，
/// 一次读全量比递归查询简单可靠，也避免了 N+1。
class FolderRepository {
  FolderRepository(this._db);

  final AppDatabase _db;
  final _uuid = const Uuid();

  Stream<List<Folder>> watchAll() => _db.watchFolders();

  Future<List<Folder>> all() => _db.allFolders();

  Future<Folder?> byId(String id) => _db.getFolder(id);

  Future<int> noteCount(String folderId) => _db.folderNoteCount(folderId);

  Future<Folder> create({String name = '新目录', String? parentId}) async {
    final now = DateTime.now().toUtc();
    final id = _uuid.v4();
    await _db.upsertFolder(FoldersCompanion.insert(
      id: id,
      name: name.trim().isEmpty ? '新目录' : name.trim(),
      parentId: Value(parentId),
      createdAt: now,
      updatedAt: now,
    ));
    return (await _db.getFolder(id))!;
  }

  Future<void> rename(String id, String name) async {
    if (name.trim().isEmpty) return;
    await _db.renameFolder(id, name);
  }

  /// 删除目录。里面的笔记会回到轻笔记，不会跟着被删。
  Future<void> softDelete(String id) => _db.softDeleteFolder(id);

  /// 把目录组织成树。返回顶层目录列表，每个节点带子节点与笔记数。
  static List<FolderNode> buildTree(
    List<Folder> folders,
    Map<String, int> counts,
  ) {
    final byParent = <String?, List<Folder>>{};
    for (final f in folders) {
      byParent.putIfAbsent(f.parentId, () => []).add(f);
    }

    List<FolderNode> build(String? parentId, int depth) {
      final children = byParent[parentId] ?? const <Folder>[];
      return children.map((f) {
        return FolderNode(
          folder: f,
          depth: depth,
          noteCount: counts[f.id] ?? 0,
          children: build(f.id, depth + 1),
        );
      }).toList(growable: false);
    }

    return build(null, 0);
  }
}

/// 树节点。深度用于缩进展示。
class FolderNode {
  const FolderNode({
    required this.folder,
    required this.depth,
    required this.noteCount,
    required this.children,
  });

  final Folder folder;
  final int depth;
  final int noteCount;
  final List<FolderNode> children;

  bool get hasChildren => children.isNotEmpty;

  /// 先序遍历展开成扁平列表，方便 ListView.builder 使用
  void flatten(List<FolderNode> out) {
    out.add(this);
    for (final c in children) {
      c.flatten(out);
    }
  }
}
