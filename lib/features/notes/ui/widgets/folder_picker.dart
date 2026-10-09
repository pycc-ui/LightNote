import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/db/app_database.dart';
import '../../../../core/theme/dimens.dart';
import '../../../../core/util/text_utils.dart';
import '../../../folders/data/folder_repository.dart';

/// 选择目录的底部弹窗。用于「加入笔记库」「移动目录」。
///
/// 提供「新建目录」入口，避免用户因为还没建目录而卡住流程——
/// 这是这类两段式（速记 → 归档）设计最常见的流失点。
///
/// 返回选中的 folderId；用户取消则返回 null。
Future<String?> showFolderPicker(
  BuildContext context, {
  String title = '选择目录',
  String? currentFolderId,
  bool allowRemoveFromFolder = false,
}) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _FolderPickerSheet(
      title: title,
      currentFolderId: currentFolderId,
      allowRemoveFromFolder: allowRemoveFromFolder,
    ),
  );
}

/// 哨兵值：表示「移出目录 / 回到轻笔记」
const kRemoveFromFolder = '__remove_from_folder__';

class _FolderPickerSheet extends StatefulWidget {
  const _FolderPickerSheet({
    required this.title,
    this.currentFolderId,
    this.allowRemoveFromFolder = false,
  });

  final String title;
  final String? currentFolderId;
  final bool allowRemoveFromFolder;

  @override
  State<_FolderPickerSheet> createState() => _FolderPickerSheetState();
}

class _FolderPickerSheetState extends State<_FolderPickerSheet> {
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
    final repo = context.read<FolderRepository>();

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
                      icon: Icon(_creating ? Icons.close : Icons.create_new_folder_outlined,
                          size: 18),
                      label: Text(_creating ? '取消新建' : '新建目录'),
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
                            hintText: '目录名称',
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
                child: StreamBuilder<List<Folder>>(
                  stream: repo.watchAll(),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Padding(
                        padding: EdgeInsets.all(AppSpacing.lg),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    final folders = snapshot.data!;

                    return ListView(
                      shrinkWrap: true,
                      children: [
                        if (widget.allowRemoveFromFolder)
                          ListTile(
                            leading: const Icon(Icons.inbox_outlined),
                            title: const Text('移出目录（回到轻笔记）'),
                            onTap: () =>
                                Navigator.pop(context, kRemoveFromFolder),
                          ),
                        if (folders.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(AppSpacing.lg),
                            child: Column(
                              children: [
                                Icon(Icons.folder_off_outlined,
                                    size: 40,
                                    color: theme.colorScheme.outline),
                                const SizedBox(height: AppSpacing.sm),
                                Text('还没有目录',
                                    style: theme.textTheme.bodyMedium),
                                const SizedBox(height: AppSpacing.xs),
                                Text(
                                  '点上方「新建目录」创建一个，例如「工作笔记」',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        for (final f in folders)
                          ListTile(
                            leading: const Icon(Icons.folder_outlined),
                            title: Text(f.name),
                            trailing: f.id == widget.currentFolderId
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

  Future<void> _createAndPick(FolderRepository repo) async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    final folder = await repo.create(name: name);
    if (!mounted) return;
    Navigator.pop(context, folder.id);
  }
}

/// 新建笔记 / 新建目录 的二选一弹窗（笔记库页 `+` 按钮）
Future<String?> showCreateSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (_) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.note_add_outlined),
            title: const Text('新建笔记'),
            subtitle: const Text('创建后可直接开始编辑'),
            onTap: () => Navigator.pop(context, 'note'),
          ),
          ListTile(
            leading: const Icon(Icons.create_new_folder_outlined),
            title: const Text('新建目录'),
            subtitle: const Text('用于归档正式笔记'),
            onTap: () => Navigator.pop(context, 'folder'),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ),
    ),
  );
}

/// 重命名目录弹窗
Future<String?> showRenameFolderDialog(
  BuildContext context, {
  required String currentName,
}) async {
  final controller = TextEditingController(text: currentName);
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('重命名目录'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: '目录名称'),
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

/// 笔记列表项（笔记库 / 目录详情共用）
class NoteListTile extends StatelessWidget {
  const NoteListTile({
    required this.note,
    required this.onTap,
    this.onLongPress,
    this.showFolderHint = false,
    super.key,
  });

  final Note note;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool showFolderHint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = note.title.trim().isEmpty ? '无标题' : note.title.trim();

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        constraints: const BoxConstraints(minHeight: kMinListItemHeight),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm + 4,
        ),
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
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
            if (showFolderHint && note.folderId != null) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(Icons.folder_outlined,
                      size: 12, color: theme.colorScheme.outline),
                  const SizedBox(width: 4),
                  _FolderName(folderId: note.folderId!),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 懒加载目录名，避免列表项额外查询拖慢滚动
class _FolderName extends StatelessWidget {
  const _FolderName({required this.folderId});

  final String folderId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<Folder?>(
      future: context.read<FolderRepository>().byId(folderId),
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
