import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';

import '../../../../core/db/models.dart';
import '../../../../core/theme/dimens.dart';
import '../../../../core/widgets/log_bar.dart';
import '../data/note_repository.dart';

/// 轻笔记的**详情页**：看 AI 写出来的全文。
///
/// 卡片上只有标题，正文在这里。看完可以收进「我的轻笔记」——
/// 返回 `true` 表示收过了，外层据此把卡片标记成"已加入"。
///
/// 这是一个**只读预览**：内容还没进数据库，所以没有"编辑"的概念。
/// 收下之后它就是一条普通笔记，在「我的轻笔记」里可以正常编辑。
class FeedDetailPage extends StatefulWidget {
  const FeedDetailPage({super.key, required this.draft});

  final FeedDraft draft;

  @override
  State<FeedDetailPage> createState() => _FeedDetailPageState();
}

class _FeedDetailPageState extends State<FeedDetailPage> {
  bool _added = false;
  bool _saving = false;

  Future<void> _addToInbox() async {
    if (_added || _saving) return;
    setState(() => _saving = true);
    try {
      await context.read<NoteRepository>().createInbox(
            title: widget.draft.title,
            content: widget.draft.body,
          );
      if (!mounted) return;
      setState(() {
        _added = true;
        _saving = false;
      });
      LogBar.success(context, '已加入「我的轻笔记」');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      LogBar.error(context, '保存失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // 把"收下没有"带回列表，让卡片显示成已加入
        Navigator.of(context).pop(_added);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('轻笔记'),
          actions: [
            if (!_added)
              TextButton.icon(
                onPressed: _saving ? null : _addToInbox,
                icon: _saving
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.bolt_outlined, size: 18),
                label: const Text('加入我的轻笔记'),
              )
            else
              Padding(
                padding: const EdgeInsets.only(right: AppSpacing.md),
                child: Row(
                  children: [
                    Icon(Icons.check_circle_outline,
                        size: 18, color: scheme.primary),
                    const SizedBox(width: 4),
                    Text(
                      '已加入',
                      style: theme.textTheme.labelLarge
                          ?.copyWith(color: scheme.primary),
                    ),
                  ],
                ),
              ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.xxl,
          ),
          children: [
            Text(
              widget.draft.title,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Icon(Icons.auto_awesome, size: 13, color: scheme.primary),
                const SizedBox(width: 4),
                Text(
                  'AI 从你的笔记库生成',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
            const Divider(height: AppSpacing.xl),
            MarkdownBody(
              data: widget.draft.body,
              styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                p: theme.textTheme.bodyLarge?.copyWith(height: 1.7),
                h1: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
                h2: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
                h3: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
                blockSpacing: AppSpacing.md,
                listIndent: 20,
              ),
              // 正文里可能有链接，详情页允许点击（卡片上不允许）
              onTapLink: (_, __, ___) {},
            ),
          ],
        ),
      ),
    );
  }
}