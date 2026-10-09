import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/db/app_database.dart';
import '../../../core/theme/dimens.dart';
import '../../cards/domain/card_repository.dart';
import '../../cards/ui/review_page.dart';
import '../../folders/data/folder_repository.dart';
import '../data/note_repository.dart';
import 'folder_detail_page.dart';
import 'note_editor_page.dart';
import 'search_page.dart';
import 'widgets/folder_picker.dart';
import 'widgets/section_header.dart';

/// 笔记库 / 目录页（设计稿 §5.2 / 线框图 4.2）。
///
/// 结构：目录区 + 最近笔记区。
/// 目录层级用缩进展示（parentId 支持嵌套，但 MVP 不做拖拽排序）。
class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final notes = context.read<NoteRepository>();
    final folders = context.read<FolderRepository>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('笔记库'),
        actions: [
          IconButton(
            tooltip: '搜索',
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SearchPage()),
            ),
          ),
          IconButton(
            tooltip: '更多',
            icon: const Icon(Icons.more_vert),
            onPressed: () => _showMoreMenu(context),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: '新建',
        onPressed: () => _onCreate(context),
        child: const Icon(Icons.add),
      ),
      body: StreamBuilder<List<Note>>(
        stream: notes.watchLibrary(),
        builder: (context, noteSnap) {
          if (noteSnap.hasError) {
            return Center(child: Text('加载失败：${noteSnap.error}'));
          }
          if (!noteSnap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final recent = noteSnap.data!;

          return StreamBuilder<List<Folder>>(
            stream: folders.watchAll(),
            builder: (context, folderSnap) {
              if (!folderSnap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final folderList = folderSnap.data!;

              return ListView(
                padding: const EdgeInsets.fromLTRB(0, AppSpacing.sm, 0, 96),
                children: [
                  const SectionHeader(title: '目录'),
                  if (folderList.isEmpty)
                    _EmptyFolders(
                      onCreate: () => _createFolder(context),
                    )
                  else
                    _FolderList(
                      folders: folderList,
                      onOpen: (f) => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => FolderDetailPage(folderId: f.id),
                        ),
                      ),
                      onDelete: (f) => _deleteFolder(context, f),
                    ),
                  const SizedBox(height: AppSpacing.sm),
                  const SectionHeader(title: '最近笔记'),
                  if (recent.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                        vertical: AppSpacing.lg,
                      ),
                      child: Text(
                        '还没有正式笔记。\n'
                        '可以点右下角 + 新建，或把「轻笔记」里的速记加入笔记库。',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.6,
                        ),
                      ),
                    )
                  else
                    for (final n in recent)
                      NoteListTile(
                        note: n,
                        showFolderHint: true,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => NoteEditorPage(noteId: n.id),
                          ),
                        ),
                        onLongPress: () => _noteActions(context, n),
                      ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  void _showMoreMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.search),
              title: const Text('搜索笔记'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SearchPage()),
                );
              },
            ),
            // 记忆卡片复习的入口。设计稿的底部导航只有 4 个位置，
            // 放不下复习页，但 SM-2 复习是最初需求里的核心能力，必须有入口。
            ListTile(
              leading: const Icon(Icons.style_outlined),
              title: const Text('记忆卡片复习'),
              subtitle: const _DueCountSubtitle(),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ReviewPage()),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onCreate(BuildContext context) async {
    final choice = await showCreateSheet(context);
    if (choice == null || !context.mounted) return;

    if (choice == 'folder') {
      await _createFolder(context);
      return;
    }

    // 新建笔记：先问要不要直接归到某个目录
    final folderId = await showFolderPicker(
      context,
      title: '新建到哪个目录？',
      allowRemoveFromFolder: true,
    );
    if (!context.mounted) return;

    final repo = context.read<NoteRepository>();
    final note = (folderId == null || folderId == kRemoveFromFolder)
        ? await repo.createLibrary()
        : await repo.createInFolder(folderId);

    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NoteEditorPage(noteId: note.id,startInPreview: false)),
    );
  }

  Future<void> _createFolder(BuildContext context) async {
    final repo = context.read<FolderRepository>();
    final name = await showRenameFolderDialog(context, currentName: '');
    if (name == null || !context.mounted) return;
    await repo.create(name: name);
  }

  Future<void> _deleteFolder(BuildContext context, Folder folder) async {
    final repo = context.read<FolderRepository>();
    final count = await repo.noteCount(folder.id);

    if (!context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除目录「${folder.name}」'),
        content: Text(
          count == 0
              ? '该目录为空，删除后不可恢复。'
              : '该目录下有 $count 篇笔记。\n\n'
                  '删除目录**不会删除笔记**，这些笔记会回到「轻笔记」，'
                  '之后可以再归档到别的目录。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除目录'),
          ),
        ],
      ),
    );
    if (ok == true) await repo.softDelete(folder.id);
  }

  Future<void> _noteActions(BuildContext context, Note note) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('移动目录'),
              onTap: () => Navigator.pop(ctx, 'move'),
            ),
            ListTile(
              leading: const Icon(Icons.inbox_outlined),
              title: const Text('移回轻笔记'),
              subtitle: const Text('从笔记库退回收件箱'),
              onTap: () => Navigator.pop(ctx, 'inbox'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除笔记'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;

    final repo = context.read<NoteRepository>();
    switch (action) {
      case 'move':
        final folderId = await showFolderPicker(
          context,
          title: '移动到目录',
          currentFolderId: note.folderId,
        );
        if (folderId != null && folderId != kRemoveFromFolder) {
          await repo.moveToFolder(note.id, folderId);
        }
      case 'inbox':
        await repo.moveToInbox(note.id);
      case 'delete':
        await repo.softDelete(note.id);
    }
  }
}

/// 目录列表：支持缩进展示层级，长按弹菜单
class _FolderList extends StatelessWidget {
  const _FolderList({
    required this.folders,
    required this.onOpen,
    required this.onDelete,
  });

  final List<Folder> folders;
  final void Function(Folder) onOpen;
  final void Function(Folder) onDelete;

  @override
  Widget build(BuildContext context) {
    // 笔记数用一次性查询填充，目录数量少，开销可忽略
    final repo = context.read<FolderRepository>();
    return FutureBuilder<Map<String, int>>(
      future: _loadCounts(repo),
      builder: (context, snapshot) {
        final counts = snapshot.data ?? const <String, int>{};
        final tree = FolderRepository.buildTree(folders, counts);
        final flat = <FolderNode>[];
        for (final node in tree) {
          node.flatten(flat);
        }

        return Column(
          children: [
            for (final node in flat)
              _FolderTile(
                node: node,
                onTap: () => onOpen(node.folder),
                onLongPress: () => _menu(context, node.folder),
              ),
          ],
        );
      },
    );
  }

  Future<Map<String, int>> _loadCounts(FolderRepository repo) async {
    final all = await repo.all();
    final counts = <String, int>{};
    for (final f in all) {
      counts[f.id] = await repo.noteCount(f.id);
    }
    return counts;
  }

  Future<void> _menu(BuildContext context, Folder folder) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名'),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除目录'),
              subtitle: const Text('目录内笔记会回到轻笔记'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;

    if (action == 'rename') {
      final name = await showRenameFolderDialog(
        context,
        currentName: folder.name,
      );
      if (name != null && context.mounted) {
        await context.read<FolderRepository>().rename(folder.id, name);
      }
    } else if (action == 'delete') {
      await _deleteWithConfirm(context, folder);
    }
  }

  Future<void> _deleteWithConfirm(BuildContext context, Folder folder) async {
    final repo = context.read<FolderRepository>();
    final count = await repo.noteCount(folder.id);
    if (!context.mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除目录「${folder.name}」'),
        content: Text(
          count == 0
              ? '该目录为空，删除后不可恢复。'
              : '该目录下有 $count 篇笔记。\n\n'
                  '删除目录**不会删除笔记**，这些笔记会回到「轻笔记」。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除目录'),
          ),
        ],
      ),
    );
    if (ok == true) await repo.softDelete(folder.id);
  }
}

class _FolderTile extends StatelessWidget {
  const _FolderTile({
    required this.node,
    required this.onTap,
    required this.onLongPress,
  });

  final FolderNode node;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        constraints: const BoxConstraints(minHeight: kMinListItemHeight),
        padding: EdgeInsets.only(
          left: AppSpacing.md + node.depth * AppSpacing.lg,
          right: AppSpacing.md,
          top: AppSpacing.sm,
          bottom: AppSpacing.sm,
        ),
        child: Row(
          children: [
            Icon(Icons.folder_outlined, color: theme.colorScheme.primary),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                node.folder.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge,
              ),
            ),
            Text(
              '${node.noteCount}',
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(width: AppSpacing.sm),
            Icon(Icons.chevron_right,
                color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// 待复习数量（异步取，菜单打开时懒加载）
class _DueCountSubtitle extends StatelessWidget {
  const _DueCountSubtitle();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<int>(
      future: context.read<CardRepository>().dueCount(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const Text('SM-2 间隔重复');
        final n = snapshot.data!;
        return Text(n == 0 ? '今天没有到期卡片' : '今天有 $n 张待复习');
      },
    );
  }
}

class _EmptyFolders extends StatelessWidget {
  const _EmptyFolders({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          Icon(Icons.folder_off_outlined,
              size: 20, color: theme.colorScheme.outline),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '还没有目录',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          TextButton(onPressed: onCreate, child: const Text('新建目录')),
        ],
      ),
    );
  }
}
