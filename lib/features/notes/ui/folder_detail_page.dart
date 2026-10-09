import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/db/app_database.dart';
import '../../../core/theme/dimens.dart';
import '../../folders/data/folder_repository.dart';
import '../data/note_repository.dart';
import 'note_editor_page.dart';
import 'search_page.dart';
import 'widgets/folder_picker.dart';

/// 目录详情页（设计稿 §5.3 / 线框图 4.3）
class FolderDetailPage extends StatefulWidget {
  const FolderDetailPage({required this.folderId, super.key});

  final String folderId;

  @override
  State<FolderDetailPage> createState() => _FolderDetailPageState();
}

class _FolderDetailPageState extends State<FolderDetailPage> {
  Folder? _folder;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final f = await context.read<FolderRepository>().byId(widget.folderId);
    if (mounted) setState(() => _folder = f);
  }

  @override
  Widget build(BuildContext context) {
    final notes = context.read<NoteRepository>();
    final theme = Theme.of(context);
    final name = _folder?.name ?? '目录';

    return Scaffold(
      appBar: AppBar(
        title: Text(name),
        actions: [
          IconButton(
            tooltip: '搜索',
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SearchPage()),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: _onMenu,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('重命名目录')),
              PopupMenuItem(value: 'add_sub', child: Text('新建子目录')),
              PopupMenuItem(value: 'delete', child: Text('删除目录')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: '在此目录新建笔记',
        onPressed: _createNote,
        child: const Icon(Icons.add),
      ),
      body: StreamBuilder<List<Note>>(
        stream: notes.watchInFolder(widget.folderId),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('加载失败：${snapshot.error}'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final list = snapshot.data!;
          if (list.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.folder_open_outlined,
                        size: 52, color: theme.colorScheme.outline),
                    const SizedBox(height: AppSpacing.md),
                    Text('该目录暂无笔记', style: theme.textTheme.titleMedium),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      '点右下角 + 在这里新建一篇。',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.only(bottom: 96),
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) => NoteListTile(
              note: list[i],
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => NoteEditorPage(noteId: list[i].id),
                ),
              ),
              onLongPress: () => _noteActions(list[i]),
            ),
          );
        },
      ),
    );
  }

  Future<void> _createNote() async {
    final note = await context
        .read<NoteRepository>()
        .createInFolder(widget.folderId);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NoteEditorPage(noteId: note.id)),
    );
  }

  Future<void> _onMenu(String value) async {
    final repo = context.read<FolderRepository>();
    final folder = _folder;
    if (folder == null) return;

    switch (value) {
      case 'rename':
        final newName = await showRenameFolderDialog(
          context,
          currentName: folder.name,
        );
        if (newName != null) {
          await repo.rename(folder.id, newName);
          await _load();
        }
      case 'add_sub':
        final name = await showRenameFolderDialog(context, currentName: '');
        if (name != null) {
          await repo.create(name: name, parentId: folder.id);
        }
      case 'delete':
        final count = await repo.noteCount(folder.id);
        if (!mounted) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('删除目录「${folder.name}」'),
            content: Text(
              count == 0
                  ? '该目录为空，删除后不可恢复。'
                  : '该目录下有 $count 篇笔记。\n\n'
                      '删除目录**不会删除笔记**，它们会回到「轻笔记」。',
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
        if (ok == true && mounted) {
          await repo.softDelete(folder.id);
          if (mounted) Navigator.of(context).pop();
        }
    }
  }

  Future<void> _noteActions(Note note) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('移动到其他目录'),
              onTap: () => Navigator.pop(ctx, 'move'),
            ),
            ListTile(
              leading: const Icon(Icons.inbox_outlined),
              title: const Text('移回轻笔记'),
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
    if (action == null || !mounted) return;

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
