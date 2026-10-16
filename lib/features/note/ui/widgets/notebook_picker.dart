import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/db/app_database.dart';
import '../../../../core/theme/dimens.dart';
import '../../../../core/util/text_utils.dart';
import '../../data/notebook_repository.dart';

/// 选择笔记库的底部弹窗。用于「加入笔记库」「移动到笔记库」。
///
/// 提供「新建笔记库」入口，避免用户因为还没建笔记库而卡住流程——
/// 这是这类两段式（速记 → 归档）设计最常见的流失点。
///
/// 返回选中的 notebookId；用户取消则返回 null。
Future<String?> showNotebookPicker(
  BuildContext context, {
  String title = '选择笔记库',
  String? currentNotebookId,
  bool allowUnfile = false,
}) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _NotebookPickerSheet(
      title: title,
      currentNotebookId: currentNotebookId,
      allowUnfile: allowUnfile,
    ),
  );
}

/// 哨兵值：表示「移出笔记库 / 回到我的轻笔记」
const kUnfileNotebook = '__remove_from_folder__';

class _NotebookPickerSheet extends StatefulWidget {
  const _NotebookPickerSheet({
    required this.title,
    this.currentNotebookId,
    this.allowUnfile = false,
  });

  final String title;
  final String? currentNotebookId;
  final bool allowUnfile;

  @override
  State<_NotebookPickerSheet> createState() => _NotebookPickerSheetState();
}

class _NotebookPickerSheetState extends State<_NotebookPickerSheet> {
  bool _creating = false;
  final _nameController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repo = context.read<NotebookRepository>();

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.6,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(widget.title,
                          style: theme.textTheme.titleLarge),
                    ),
                    TextButton.icon(
                      onPressed: () =>
                          setState(() => _creating = !_creating),
                      icon: Icon(_creating ? Icons.close : Icons.library_add_outlined,
                          size: 18),
                      label: Text(_creating ? '取消新建' : '新建笔记库'),
                    ),
                  ],
                ),
              ),
              if (_creating)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _nameController,
                          autofocus: true,
                          decoration: const InputDecoration(
                            hintText: '笔记库名称',
                            isDense: true,
                          ),
                          onSubmitted: (_) => _createAndPick(repo),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      FilledButton(
                        onPressed: () => _createAndPick(repo),
                        child: const Text('创建'),
                      ),
                    ],
                  ),
                ),
              const Divider(height: 1),
              Flexible(
                child: StreamBuilder<List<Notebook>>(
                  stream: repo.watchAll(),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Padding(
                        padding: EdgeInsets.all(AppSpacing.lg),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    final notebooks = snapshot.data!;

                    return ListView(
                      shrinkWrap: true,
                      children: [
                        if (widget.allowUnfile)
                          ListTile(
                            leading: const Icon(Icons.inbox_outlined),
                            title: const Text('移出笔记库（回到我的轻笔记）'),
                            onTap: () =>
                                Navigator.pop(context, kUnfileNotebook),
                          ),
                        if (notebooks.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(AppSpacing.lg),
                            child: Column(
                              children: [
                                Icon(Icons.library_books_outlined,
                                    size: 40,
                                    color: theme.colorScheme.outline),
                                const SizedBox(height: AppSpacing.sm),
                                Text('还没有笔记库',
                                    style: theme.textTheme.bodyMedium),
                                const SizedBox(height: AppSpacing.xs),
                                Text(
                                  '点上方「新建笔记库」创建一个，例如「工作笔记」',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        for (final f in notebooks)
                          ListTile(
                            leading: const Icon(Icons.library_books_outlined),
                            title: Text(f.name),
                            trailing: f.id == widget.currentNotebookId
                                ? Icon(Icons.check,
                                    color: theme.colorScheme.primary)
                                : null,
                            onTap: () => Navigator.pop(context, f.id),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _createAndPick(NotebookRepository repo) async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    final notebook = await repo.create(name: name);
    if (!mounted) return;
    Navigator.pop(context, notebook.id);
  }
}

/// 笔记库页 `+` 按钮的三选一弹窗。
///
/// 三项都是"新建"，但目标不同。**第一项最常用，所以放最上面且不再追问**：
///   1. 直接记到「我的轻笔记」——不选笔记库，一步到位（速记的主路径）
///   2. 新建笔记并选一个笔记库归档
///   3. 新建笔记库（建容器，不是建笔记）
Future<String?> showCreateSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (_) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.bolt_outlined),
            title: const Text('新建笔记到「我的轻笔记」'),
            subtitle: const Text('随手记一句，之后再归档'),
            onTap: () => Navigator.pop(context, 'inbox'),
          ),
          ListTile(
            leading: const Icon(Icons.note_add_outlined),
            title: const Text('新建笔记并选择笔记库'),
            subtitle: const Text('创建后直接归入某个笔记库'),
            onTap: () => Navigator.pop(context, 'filed'),
          ),
          ListTile(
            leading: const Icon(Icons.library_add_outlined),
            title: const Text('新建笔记库'),
            subtitle: const Text('用于归档笔记的容器'),
            onTap: () => Navigator.pop(context, 'notebook'),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ),
    ),
  );
}

/// 重命名笔记库弹窗
Future<String?> showRenameNotebookDialog(
  BuildContext context, {
  required String currentName,
}) async {
  final controller = TextEditingController(text: currentName);
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('重命名笔记库'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: '笔记库名称'),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text.trim()),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  controller.dispose();
  return (result == null || result.isEmpty) ? null : result;
}

/// 笔记列表项（笔记库页 / 笔记库详情 / 我的轻笔记共用）
class NoteListTile extends StatelessWidget {
  const NoteListTile({
    required this.note,
    required this.onTap,
    this.onLongPress,
    this.showNotebookHint = false,
    this.selectable = false,
    this.selected = false,
    this.trailing,
    super.key,
  });

  final Note note;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool showNotebookHint;

  /// 是否处于多选模式。true 时左侧显示勾选框，[onTap] 变成切换选中。
  final bool selectable;

  /// 当前是否被选中（[selectable] 为 false 时无意义）
  final bool selected;

  /// 行尾那块（可选）。目前只有"调整顺序"模式用它放**拖动手柄** ——
  /// 手柄要显式可见，光靠"长按可以拖"没人猜得到。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = note.title.trim().isEmpty ? '无标题' : note.title.trim();

    // 多选模式下整行加一层淡淡的底色，让"已选中"一眼能看出来，
    // 而不是只能靠左边那个小勾选框。
    final bg = selectable && selected
        ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
        : null;

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        color: bg,
        constraints: const BoxConstraints(minHeight: kMinListItemHeight),
        padding: EdgeInsets.only(
          left: selectable ? AppSpacing.sm : AppSpacing.md,
          right: AppSpacing.md,
          top: AppSpacing.sm + 4,
          bottom: AppSpacing.sm + 4,
        ),
        child: Row(
          children: [
            if (selectable)
              // 用 Icon 而不是 Checkbox：Checkbox 自带 48x48 的点击区，
              // 会把整行的点击目标抢走（点哪都变成勾选，包括想点文字进详情时）。
              Padding(
                padding: const EdgeInsets.only(right: AppSpacing.sm),
                child: Icon(
                  selected
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  size: 22,
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outline,
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      if (note.pinned)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Icon(Icons.push_pin,
                              size: 14, color: theme.colorScheme.primary),
                        ),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        formatRelativeTime(note.updatedAt),
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                  if (note.excerpt.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      note.excerpt,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (showNotebookHint && note.notebookId != null) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.library_books_outlined,
                            size: 12, color: theme.colorScheme.outline),
                        const SizedBox(width: 4),
                        _NotebookName(notebookId: note.notebookId!),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

/// 懒加载笔记库名，避免列表项额外查询拖慢滚动
class _NotebookName extends StatelessWidget {
  const _NotebookName({required this.notebookId});

  final String notebookId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<Notebook?>(
      future: context.read<NotebookRepository>().byId(notebookId),
      builder: (context, snapshot) {
        final name = snapshot.data?.name;
        if (name == null) return const SizedBox.shrink();
        return Text(
          name,
          style: theme.textTheme.labelSmall
              ?.copyWith(color: theme.colorScheme.outline),
        );
      },
    );
  }
}
