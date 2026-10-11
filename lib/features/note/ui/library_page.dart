import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/db/app_database.dart';
import '../../../core/theme/dimens.dart';
import '../../../core/widgets/log_bar.dart';
import '../../ai/ui/ai_page.dart';
import '../data/notebook_repository.dart';
import '../data/note_repository.dart';
import 'notebook_detail_page.dart';
import 'note_editor_page.dart';
import 'search_page.dart';
import 'widgets/notebook_picker.dart';
import 'widgets/swipe_to_delete.dart';
import 'widgets/section_header.dart';

/// 笔记库页。
///
/// 结构：笔记库区 + 「轻笔记」区块（未归档笔记）。
/// 笔记库是平铺的，没有层级。
///
/// **速记入口在这里**：底部导航第一个 tab 已改成消费流（不产出内容），
/// 所以「随手记一句」的入口迁到了本页的 `+` →「新建笔记」。
/// 不选笔记库就是未归档，归入下面的「轻笔记」区块。
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  /// 多选模式下被选中的笔记 id。
  ///
  /// **不能用 `_selected.isEmpty` 判断是否处于多选**：空集既表示
  /// "没进多选"，也表示"进了多选但还没选"，会导致一进就退出。
  /// 所以用 [_selecting] 单独标记。
  final Set<String> _selected = {};
  bool _selecting = false;

  /// 当前列表里可见的未归档笔记 id，供"全选"使用。
  ///
  /// 在 build 里刷新。比在 AppBar 里再开一个 StreamBuilder 简单，
  /// 也不会出现"顶栏计数与列表不一致"。
  List<String> _visibleIds = const [];

  void _enterSelecting() => setState(() {
        _selecting = true;
        _selected.clear();
      });

  void _exitSelecting() => setState(() {
        _selecting = false;
        _selected.clear();
      });

  void _toggle(String id) => setState(() {
        if (!_selected.remove(id)) _selected.add(id);
      });

  @override
  Widget build(BuildContext context) {
    final notes = context.read<NoteRepository>();
    final notebooks = context.read<NotebookRepository>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: _selecting ? _selectAppBar() : _normalAppBar(context),
      // 两个 FAB 竖排：**AI 在上，新建在下**。
      //
      // AI 原先占着底部导航的一个 tab，但它是"偶尔进去聊一次"的入口，
      // 不该和三个主页面平级。挪到这里：跟"新建"同类（都是一个动作入口），
      // 放在它上面既不抢主流程，又随时够得着。
      floatingActionButton: _selecting
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                FloatingActionButton.small(
                  heroTag: 'ai',
                  tooltip: 'AI 助手',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AiPage()),
                  ),
                  child: const Icon(Icons.auto_awesome_outlined),
                ),
                const SizedBox(height: AppSpacing.sm),
                FloatingActionButton(
                  heroTag: 'create',
                  tooltip: '新建',
                  onPressed: () => _onCreate(context),
                  child: const Icon(Icons.add),
                ),
              ],
            ),
      bottomNavigationBar: _selecting ? _batchBar(context) : null,
      body: StreamBuilder<List<Note>>(
        // 未归档笔记（原「最近笔记」换成了「轻笔记」区块的内容）
        stream: notes.watchUnfiled(),
        builder: (context, noteSnap) {
          if (noteSnap.hasError) {
            return Center(child: Text('加载失败：${noteSnap.error}'));
          }
          if (!noteSnap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final unfiled = noteSnap.data!;
          // 供顶栏"全选"用。在 build 里刷新，不用再开一个 stream。
          _visibleIds = unfiled.map((n) => n.id).toList(growable: false);

          return StreamBuilder<List<Notebook>>(
            stream: notebooks.watchAll(),
            builder: (context, folderSnap) {
              if (!folderSnap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final notebookList = folderSnap.data!;

              return ListView(
                padding: const EdgeInsets.fromLTRB(0, AppSpacing.sm, 0, 96),
                children: [
                  const SectionHeader(title: '笔记库'),
                  if (notebookList.isEmpty)
                    _EmptyNotebooks(
                      onCreate: () => _createNotebook(context),
                    )
                  else
                    _NotebookList(
                      notebooks: notebookList,
                      onOpen: (f) => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => NotebookDetailPage(notebookId: f.id),
                        ),
                      ),
                      onDelete: (f) => _deleteNotebook(context, f),
                    ),
                  const SizedBox(height: AppSpacing.sm),
                  const SectionHeader(title: '我的轻笔记'),
                  if (unfiled.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                        vertical: AppSpacing.lg,
                      ),
                      child: Text(
                        '还没有轻笔记。\n'
                        '点右下角 + 「新建笔记」随手记一句，'
                        '之后再归档到上面的笔记库。',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.6,
                        ),
                      ),
                    )
                  else
                    for (final n in unfiled)
                      SwipeToDelete(
                        itemKey: ValueKey(n.id),
                        onDelete: () => _deleteNote(context, n),
                        child: NoteListTile(
                          note: n,
                          showNotebookHint: false,
                          selectable: _selecting,
                          selected: _selected.contains(n.id),
                          onTap: () {
                            if (_selecting) {
                              _toggle(n.id);
                              return;
                            }
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => NoteEditorPage(
                                  noteId: n.id,
                                  startInReading: true,
                                ),
                              ),
                            );
                          },
                          // 多选时长按也切换选中，而不是弹菜单——
                          // 否则用户会以为长按能退出多选
                          onLongPress: _selecting
                              ? () => _toggle(n.id)
                              : () => _noteActions(context, n),
                        ),
                      ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  /// 常态顶栏：搜索、更多（更多里进多选）。
  ///
  /// 「记忆卡片复习」的入口已随功能一起移除；AI 助手的入口移到了右下角
  /// 那两个 FAB（见 build）。
  PreferredSizeWidget _normalAppBar(BuildContext context) {
    return AppBar(
      title: const Text('笔记库'),
      actions: [
        IconButton(
          tooltip: '搜索全部笔记',
          icon: const Icon(Icons.search),
          onPressed: () => Navigator.of(context).push(
            // 不传范围 = 全局搜索，包含「我的轻笔记」里的未归档笔记
            MaterialPageRoute(builder: (_) => const SearchPage()),
          ),
        ),
        PopupMenuButton<String>(
          tooltip: '更多',
          onSelected: (v) {
            if (v == 'select') _enterSelecting();
          },
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: 'select',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.checklist),
                title: Text('多选笔记'),
                subtitle: Text('批量移动或删除我的轻笔记'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 多选顶栏：退出、计数、全选。
  PreferredSizeWidget _selectAppBar() {
    final allSelected =
        _visibleIds.isNotEmpty && _selected.length == _visibleIds.length;
    return AppBar(
      leading: IconButton(
        tooltip: '退出多选',
        icon: const Icon(Icons.close),
        onPressed: _exitSelecting,
      ),
      title: Text('已选 ${_selected.length} 条'),
      actions: [
        TextButton(
          onPressed: _visibleIds.isEmpty
              ? null
              : () => setState(() {
                    if (allSelected) {
                      _selected.clear();
                    } else {
                      _selected
                        ..clear()
                        ..addAll(_visibleIds);
                    }
                  }),
          child: Text(allSelected ? '全不选' : '全选'),
        ),
      ],
    );
  }

  /// 批量操作条：移动 / 删除。
  Widget _batchBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = _selected.isNotEmpty;

    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                enabled ? '已选 ${_selected.length} 条' : '请选择要处理的笔记',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            TextButton.icon(
              onPressed: enabled ? () => _batchMove(context) : null,
              icon: const Icon(Icons.drive_file_move_outline, size: 18),
              label: const Text('移动'),
            ),
            const SizedBox(width: AppSpacing.sm),
            TextButton.icon(
              onPressed: enabled ? () => _batchDelete(context) : null,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('删除'),
              style: TextButton.styleFrom(foregroundColor: scheme.error),
            ),
          ],
        ),
      ),
    );
  }

  /// 批量移动。选「我的轻笔记」即移出笔记库。
  Future<void> _batchMove(BuildContext context) async {
    final ids = _selected.toList(growable: false);
    final target = await showNotebookPicker(
      context,
      title: '把 ${ids.length} 条移动到…',
      allowUnfile: true,
    );
    if (target == null || !context.mounted) return;

    final repo = context.read<NoteRepository>();
    final moved = target == kUnfileNotebook
        ? await repo.moveManyToNotebook(ids, null)
        : await repo.moveManyToNotebook(ids, target);
    if (!context.mounted) return;

    _exitSelecting();
    LogBar.success(context, '已移动 $moved 条');
  }

  /// 批量删除。
  ///
  /// 多选删除**不能像单条那样给撤销**：一次删几十条时，
  /// 把它们的完整状态留在内存里等撤销代价太大，而且用户点了"删除"
  /// 再撤销的概率很低。所以这里用二次确认。
  Future<void> _batchDelete(BuildContext context) async {
    final n = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除 $n 条笔记'),
        content: const Text('这些笔记将被删除，不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    final ids = _selected.toList(growable: false);
    await context.read<NoteRepository>().softDeleteMany(ids);
    if (!context.mounted) return;

    _exitSelecting();
    LogBar.info(context, '已删除 $n 条');
  }

  /// 单条删除（左滑触发）。
  ///
  /// 用**乐观删除 + 撤销**而不是二次确认：左滑手势本身已经是明确的意图
  /// 表达，再弹对话框是多余的一步；给撤销既快又不怕手滑。
  Future<void> _deleteNote(BuildContext context, Note note) async {
    final repo = context.read<NoteRepository>();
    await repo.softDelete(note.id);
    if (!context.mounted) return;

    LogBar.action(
      context,
      '已删除「${note.title.trim().isEmpty ? '无标题' : note.title.trim()}」',
      actionLabel: '撤销',
      persist: false,
      onAction: () => repo.restore(note.id),
    );
  }

  Future<void> _onCreate(BuildContext context) async {
    final choice = await showCreateSheet(context);
    if (choice == null || !context.mounted) return;

    switch (choice) {
      // 1) 直接记到「我的轻笔记」——不选笔记库，一步到位。
      //    这是最常用的路径，所以放在第一项、且不再多问一次。
      case 'inbox':
        await _newNote(context, null);

      // 2) 新建笔记并选一个笔记库归档
      case 'filed':
        final notebookId = await showNotebookPicker(
          context,
          title: '新建到哪个笔记库？',
        );
        if (notebookId == null || !context.mounted) return;
        await _newNote(context, notebookId);

      // 3) 新建笔记库（不是笔记）
      case 'notebook':
        await _createNotebook(context);
    }
  }

  /// 进编辑页新建一条笔记。
  ///
  /// **不再先创建再打开**：那样用户什么都不写就返回会留下空白笔记。
  /// 现在只把"落到哪个笔记库"作为草稿参数传进去，编辑页在第一次
  /// 真正落盘时才创建（见 [NoteDraftParams]）。
  Future<void> _newNote(BuildContext context, String? notebookId) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NoteEditorPage(
          draft: NoteDraftParams(
            notebookId: notebookId,
            asInbox: notebookId == null,
          ),
        ),
      ),
    );
  }

  Future<void> _createNotebook(BuildContext context) async {
    final repo = context.read<NotebookRepository>();
    final name = await showRenameNotebookDialog(context, currentName: '');
    if (name == null || !context.mounted) return;
    await repo.create(name: name);
  }

  Future<void> _deleteNotebook(BuildContext context, Notebook folder) async {
    final repo = context.read<NotebookRepository>();
    final count = await repo.noteCount(folder.id);

    if (!context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除笔记库「${folder.name}」'),
        content: Text(
          count == 0
              ? '该笔记库为空，删除后不可恢复。'
              : '该笔记库下有 $count 篇笔记。\n\n'
                  '删除笔记库**不会删除笔记**，这些笔记会回到「轻笔记」，'
                  '之后可以再归档到别的笔记库。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除笔记库'),
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
              title: const Text('移动到笔记库'),
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
        final notebookId = await showNotebookPicker(
          context,
          title: '移动到笔记库',
          currentNotebookId: note.notebookId,
        );
        if (notebookId != null && notebookId != kUnfileNotebook) {
          await repo.moveToNotebook(note.id, notebookId);
        }
      case 'inbox':
        await repo.moveToInbox(note.id);
      case 'delete':
        await repo.softDelete(note.id);
    }
  }
}

/// 笔记库列表：支持缩进展示层级，长按弹菜单
class _NotebookList extends StatelessWidget {
  const _NotebookList({
    required this.notebooks,
    required this.onOpen,
    required this.onDelete,
  });

  final List<Notebook> notebooks;
  final void Function(Notebook) onOpen;
  final void Function(Notebook) onDelete;

  @override
  Widget build(BuildContext context) {
    // 笔记数用一次性查询填充，笔记库数量少，开销可忽略
    final repo = context.read<NotebookRepository>();
    return FutureBuilder<Map<String, int>>(
      future: _loadCounts(repo),
      builder: (context, snapshot) {
        final counts = snapshot.data ?? const <String, int>{};
        // 平铺渲染：笔记库没有层级（去掉了 parent_id），
        // 所以不再需要 buildTree + flatten 那套。
        return Column(
          children: [
            for (final n in notebooks)
              _NotebookTile(
                notebook: n,
                noteCount: counts[n.id] ?? 0,
                onTap: () => onOpen(n),
                onLongPress: () => _menu(context, n),
              ),
          ],
        );
      },
    );
  }

  Future<Map<String, int>> _loadCounts(NotebookRepository repo) async {
    final all = await repo.all();
    final counts = <String, int>{};
    for (final f in all) {
      counts[f.id] = await repo.noteCount(f.id);
    }
    return counts;
  }

  Future<void> _menu(BuildContext context, Notebook folder) async {
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
              title: const Text('删除笔记库'),
              subtitle: const Text('笔记库内笔记会回到轻笔记'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;

    if (action == 'rename') {
      final name = await showRenameNotebookDialog(
        context,
        currentName: folder.name,
      );
      if (name != null && context.mounted) {
        await context.read<NotebookRepository>().rename(folder.id, name);
      }
    } else if (action == 'delete') {
      await _deleteWithConfirm(context, folder);
    }
  }

  Future<void> _deleteWithConfirm(BuildContext context, Notebook folder) async {
    final repo = context.read<NotebookRepository>();
    final count = await repo.noteCount(folder.id);
    if (!context.mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除笔记库「${folder.name}」'),
        content: Text(
          count == 0
              ? '该笔记库为空，删除后不可恢复。'
              : '该笔记库下有 $count 篇笔记。\n\n'
                  '删除笔记库**不会删除笔记**，这些笔记会回到「轻笔记」。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除笔记库'),
          ),
        ],
      ),
    );
    if (ok == true) await repo.softDelete(folder.id);
  }
}

class _NotebookTile extends StatelessWidget {
  const _NotebookTile({
    required this.notebook,
    required this.noteCount,
    required this.onTap,
    required this.onLongPress,
  });

  final Notebook notebook;
  final int noteCount;
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
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: [
            Icon(Icons.library_books_outlined,
                color: theme.colorScheme.primary),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                notebook.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge,
              ),
            ),
            Text(
              '$noteCount',
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

class _EmptyNotebooks extends StatelessWidget {
  const _EmptyNotebooks({required this.onCreate});

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
          Icon(Icons.library_books_outlined,
              size: 20, color: theme.colorScheme.outline),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '还没有笔记库',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          TextButton(onPressed: onCreate, child: const Text('新建笔记库')),
        ],
      ),
    );
  }
}
