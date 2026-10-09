import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

// 隐藏 Drift 的 Card 类（由 cards 表生成），避免与 Flutter 的 Card 组件冲突。
import '../../../core/db/app_database.dart' hide Card;
import '../../../core/theme/dimens.dart';
import '../../../core/ui/log_bar.dart';
import '../../../core/util/text_utils.dart';
import '../../folders/data/folder_repository.dart';
import '../data/note_repository.dart';
import 'note_editor_page.dart';
import 'widgets/folder_picker.dart';

/// 轻笔记页（设计稿 §5.1 / 线框图 4.1）。
///
/// 这里是「速记收件箱」：随手记下的内容先进这里，
/// 之后再决定归档到哪个目录。职责单一——不做目录管理，只做快速记录与分流。
class InboxPage extends StatelessWidget {
  const InboxPage({super.key});

  @override
  Widget build(BuildContext context) {
    final notes = context.read<NoteRepository>();

    return Scaffold(
      appBar: AppBar(title: const Text('轻笔记')),
      body: StreamBuilder<List<Note>>(
        stream: notes.watchInbox(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return _ErrorView(message: '${snapshot.error}');
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final list = snapshot.data!;
          if (list.isEmpty) {
            return const _EmptyInbox();
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.md,
              96,
            ),
            itemCount: list.length,
            separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
            itemBuilder: (context, i) => QuickNoteCard(
              note: list[i],
              onTap: () => _open(context, list[i].id),
              onArchive: () => _archive(context, list[i]),
              onDelete: () => _confirmDelete(context, notes, list[i]),
            ),
          );
        },
      ),
    );
  }

  Future<void> _open(BuildContext context, String noteId) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NoteEditorPage(noteId: noteId)),
    );
  }

  /// 加入笔记库：选目录 → 归档
  Future<void> _archive(BuildContext context, Note note) async {
    final folderId = await showFolderPicker(
      context,
      title: '加入笔记库',
    );
    if (folderId == null || !context.mounted) return;

    final folders = context.read<FolderRepository>();
    await context.read<NoteRepository>().moveToFolder(note.id, folderId);

    if (!context.mounted) return;
    final name = (await folders.byId(folderId))?.name ?? '目录';
    LogBar.action(
      context,
      '已加入「$name」',
      actionLabel: '撤销',
      onAction: () {
        context.read<NoteRepository>().moveToInbox(note.id);
      },
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    NoteRepository repo,
    Note note,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除轻笔记'),
        content: Text(
          '「${note.title.trim().isEmpty ? '无标题' : note.title.trim()}」将被删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) await repo.softDelete(note.id);
  }
}

/// 轻笔记卡片（线框图 4.1）
class QuickNoteCard extends StatelessWidget {
  const QuickNoteCard({
    required this.note,
    required this.onTap,
    required this.onArchive,
    required this.onDelete,
    super.key,
  });

  final Note note;
  final VoidCallback onTap;
  final VoidCallback onArchive;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = note.title.trim().isEmpty ? '无标题' : note.title.trim();

    return Card(
      child: InkWell(
        onTap: onTap,
        onLongPress: onDelete,
        borderRadius: AppRadius.cardRadius,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
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
                const SizedBox(height: 6),
                Text(
                  note.excerpt,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Text(
                    '${note.wordCount} 字',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                  const Spacer(),
                  if (note.lastAiAt != null)
                    Padding(
                      padding: const EdgeInsets.only(right: AppSpacing.sm),
                      child: Icon(Icons.auto_awesome,
                          size: 14, color: theme.colorScheme.tertiary),
                    ),
                  TextButton.icon(
                    onPressed: onArchive,
                    icon: const Icon(Icons.library_add_outlined, size: 16),
                    label: const Text('加入笔记库'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyInbox extends StatelessWidget {
  const _EmptyInbox();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.bolt_outlined, size: 56, color: theme.colorScheme.outline),
            const SizedBox(height: AppSpacing.md),
            Text('暂无轻笔记', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '想到什么就点右下角「记一笔」写下。\n'
              '这些速记会先待在这里，之后再点「加入笔记库」归到目录里。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: AppSpacing.sm),
            Text('加载失败：$message', textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
