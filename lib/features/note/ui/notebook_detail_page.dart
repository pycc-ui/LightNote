import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/db/app_database.dart';
import '../../../core/theme/dimens.dart';
import '../../../core/widgets/log_bar.dart';
import '../data/notebook_repository.dart';
import '../data/note_repository.dart';
import 'note_editor_page.dart';
import 'search_page.dart';
import 'widgets/notebook_picker.dart';
import 'widgets/swipe_actions.dart';

/// 笔记库详情页
class NotebookDetailPage extends StatefulWidget {
  const NotebookDetailPage({required this.notebookId, super.key});

  final String notebookId;

  @override
  State<NotebookDetailPage> createState() => _FolderDetailPageState();
}

class _FolderDetailPageState extends State<NotebookDetailPage> {
  Notebook? _folder;

  /// 多选状态。见 library_page 里同名字段的说明——
  /// **不能用 `_selected.isEmpty` 判断是否在多选**。
  final Set<String> _selected = {};
  bool _selecting = false;
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

  /// 批量移动。目标可以是别的笔记库，也可以是「我的轻笔记」（移出本库）。
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

  /// 单条删除（左滑）。乐观删除 + 撤销，不弹确认。
  /// 置顶 / 取消置顶。
  ///
  /// **置顶 = 挪到最前 + 打个标记**（不是"以后一直压着别人"）：
  ///   · 置顶：把这篇排到当前顺序的第一位，`pinned` 置位（列表里显示个图钉）；
  ///   · 取消置顶：只把标记清掉，**位置不动** —— 它就在你上次放的地方。
  ///
  /// [order] 是**当前列表的完整顺序**（调用方手里就有，见 `list`）。
  /// 重编号需要完整顺序，漏了谁谁就会掉回"没排过"那组跑到最前面去。
  Future<void> _togglePin(Note note, List<String> order) async {
    final repo = context.read<NoteRepository>();
    final title = note.title.trim().isEmpty ? '无标题' : note.title.trim();
    if (note.pinned) {
      await repo.setPinned(note.id, false);
      if (!mounted) return;
      LogBar.success(context, '已取消置顶「$title」');
      return;
    }
    await repo.setPinned(note.id, true);
    await repo.moveToFront(order, note.id);
    if (!mounted) return;
    LogBar.success(context, '已置顶「$title」');
  }

  Future<void> _deleteNote(Note note) async {
    final repo = context.read<NoteRepository>();
    await repo.softDelete(note.id);
    if (!mounted) return;

    LogBar.action(
      context,
      '已删除「${note.title.trim().isEmpty ? '无标题' : note.title.trim()}」',
      actionLabel: '撤销',
      persist: false,
      onAction: () => repo.restore(note.id),
    );
  }

  /// 正在调整顺序（拖动排序模式）。
  ///
  /// 和多选互斥：两种模式下点击/长按的含义完全不同，同时开着必然打架。
  bool _reordering = false;

  void _enterReordering() {
    setState(() {
      _selecting = false;
      _selected.clear();
      _reordering = true;
    });
  }

  void _exitReordering() => setState(() => _reordering = false);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final f = await context.read<NotebookRepository>().byId(widget.notebookId);
    if (mounted) setState(() => _folder = f);
  }

  @override
  Widget build(BuildContext context) {
    final notes = context.read<NoteRepository>();
    final theme = Theme.of(context);
    final name = _folder?.name ?? '笔记库';

    return Scaffold(
      appBar: _selecting ? _selectAppBar() : _normalAppBar(name, context),
      // 多选 / 调整顺序时都不给这个按钮：那两个模式下用户要做的不是新建，
      // 浮在那儿只会占地方、还可能挡住列表最后一行
      floatingActionButton: _selecting || _reordering
          ? null
          : FloatingActionButton(
              tooltip: '在此笔记库新建笔记',
              onPressed: _createNote,
              child: const Icon(Icons.add),
            ),
      bottomNavigationBar: _selecting ? _batchBar(context) : null,
      body: StreamBuilder<List<Note>>(
        stream: notes.watchNotesInNotebook(widget.notebookId),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('加载失败：${snapshot.error}'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final list = snapshot.data!;
          _visibleIds = list.map((n) => n.id).toList(growable: false);
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
                    Text('该笔记库暂无笔记', style: theme.textTheme.titleMedium),
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

          // ---- 调整顺序模式：整个列表交给拖动手柄 ----
          //
          // 这个模式下**不套 SwipeActions**：左滑手势和拖动会抢，
          // 而且此刻用户的意图只有一个 —— 挪位置。
          if (_reordering) {
            return Column(
              children: [
                _reorderHint(list.length),
                Expanded(
                  child: ReorderableListView.builder(
                    padding: const EdgeInsets.only(bottom: 96),
                    itemCount: list.length,
                    // 顺序的**持久化**：把拖完的新顺序整份写回去
                    //（重编号是密集的，必须给完整顺序，见 `reorderNotes`）
                    // 用 `onReorderItem`（而不是老的 `onReorder`）：它给的
                    // newIndex **已经**替算好"移除原位置之后"的下标 ——
                    // 老回调那个"自己减一"的坑它内置处理了。
                    onReorderItem: (oldIndex, newIndex) {
                      final ids = [for (final n in list) n.id];
                      final moved = ids.removeAt(oldIndex);
                      ids.insert(newIndex, moved);
                      context.read<NoteRepository>().reorder(ids);
                    },
                    itemBuilder: (context, i) {
                      final n = list[i];
                      return NoteListTile(
                        key: ValueKey('reorder-${n.id}'),
                        note: n,
                        // 拖动模式下不响应点击（点一下跳到编辑页会很突兀），
                        // 手柄才是这一行唯一的作用点
                        onTap: () {},
                        trailing: ReorderableDragStartListener(
                          index: i,
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: AppSpacing.md),
                            child: Icon(Icons.drag_handle),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          }

          // 套一层：划开一行时自动收起其它行（不然可能好几行同时敞着）
          return SwipeActionsScope(
            child: ListView.separated(
              padding: EdgeInsets.only(
                bottom: _selecting ? 120 : 96,
              ),
              itemCount: list.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final n = list[i];
                return SwipeActions(
                  itemKey: ValueKey(n.id),
                  // 置顶：字段（`notes.pinned`）和排序（`pinned DESC, updated_at DESC`）
                  // 一直都是现成的，只是一直没有入口 —— 这是第一个。
                  pinned: n.pinned,
                  onTogglePin: () =>
                    _togglePin(n, [for (final x in list) x.id]),
                  onDelete: () => _deleteNote(n),
                  child: NoteListTile(
                    note: n,
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
                    onLongPress:
                        _selecting ? () => _toggle(n.id) : () => _noteActions(n),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  /// 调整顺序时顶部那条说明。
  ///
  /// 必须有：不然用户面对一个"点不动、只有手柄能用"的列表会不知所措，
  /// 也不知道怎么退出。
  Widget _reorderHint(int count) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.md, AppSpacing.xs, AppSpacing.xs, AppSpacing.xs),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '拖动右边的 ≡ 调整顺序（共 $count 篇）',
                style: theme.textTheme.bodySmall,
              ),
            ),
            TextButton(onPressed: _exitReordering, child: const Text('完成')),
          ],
        ),
      ),
    );
  }

  /// 常态顶栏。
  PreferredSizeWidget _normalAppBar(String name, BuildContext context) {
    return AppBar(
      title: Text(name),
      actions: [
        IconButton(
          tooltip: '在此笔记库内搜索',
          icon: const Icon(Icons.search),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
              // 传 notebookId → 只搜这个库。
              // 笔记库页顶栏那个搜索是全局的（含「我的轻笔记」），
              // 两者范围不同是有意的：进到库里再搜，预期是"在这个库里找"。
              builder: (_) => SearchPage(
                notebookId: widget.notebookId,
                notebookName: name,
              ),
            ),
          ),
        ),
        PopupMenuButton<String>(
          tooltip: '更多',
          onSelected: (v) {
            if (v == 'select') {
              _enterSelecting();
            } else if (v == 'reorder') {
              _enterReordering();
            } else {
              _onMenu(v);
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: 'reorder',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.swap_vert),
                title: Text('调整顺序'),
              ),
            ),
            PopupMenuItem(
              value: 'select',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.checklist),
                title: Text('多选笔记'),
              ),
            ),
            PopupMenuItem(
              value: 'rename',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.drive_file_rename_outline),
                title: Text('重命名笔记库'),
              ),
            ),
            PopupMenuItem(
              value: 'delete',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.delete_outline),
                title: Text('删除笔记库'),
              ),
            ),
            // 刻意没有「新建子笔记库」：笔记库是平铺的，不能嵌套。
            // 用数据库而不是文件系统本来就是为了不模仿目录树。
          ],
        ),
      ],
    );
  }

  Future<void> _createNote() async {
    // 不先创建再打开：用户什么都不写就返回会留下空白笔记。
    // 由编辑页在第一次真正落盘时创建（见 NoteDraftParams）。
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NoteEditorPage(
          draft: NoteDraftParams(
            notebookId: widget.notebookId,
            asInbox: false,
          ),
        ),
      ),
    );
  }

  Future<void> _onMenu(String value) async {
    final repo = context.read<NotebookRepository>();
    final folder = _folder;
    if (folder == null) return;

    switch (value) {
      case 'rename':
        final newName = await showRenameNotebookDialog(
          context,
          currentName: folder.name,
        );
        if (newName != null) {
          await repo.rename(folder.id, newName);
          await _load();
        }
      case 'delete':
        final count = await repo.noteCount(folder.id);
        if (!mounted) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('删除笔记库「${folder.name}」'),
            content: Text(
              count == 0
                  ? '该笔记库为空，删除后不可恢复。'
                  : '该笔记库下有 $count 篇笔记。\n\n'
                      '删除笔记库**不会删除笔记**，它们会回到「轻笔记」。',
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
              title: const Text('移动到其他笔记库'),
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
