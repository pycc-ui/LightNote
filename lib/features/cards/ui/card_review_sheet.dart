import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/db/models.dart';
import '../../ai/domain/ai_repository.dart';

/// 卡片确认面板。
///
/// 这是 AI 卡片进入复习队列的**唯一入口**，刻意设计成必须人工确认：
/// 直接把模型输出写库会迅速用劣质卡片淹没复习队列，
/// 而复习队列一旦被污染，用户就会放弃整个记忆卡片功能。
class CardReviewSheet extends StatefulWidget {
  const CardReviewSheet({
    required this.noteId,
    required this.drafts,
    this.model,
    super.key,
  });

  final String noteId;
  final List<CardDraft> drafts;
  final String? model;

  @override
  State<CardReviewSheet> createState() => _CardReviewSheetState();
}

class _CardReviewSheetState extends State<CardReviewSheet> {
  late List<CardDraft> _drafts;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _drafts = List.of(widget.drafts);
  }

  int get _selectedCount =>
      _drafts.where((d) => d.selected && d.isValid).length;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('确认卡片', style: theme.textTheme.titleLarge),
                        const SizedBox(height: 2),
                        Text(
                          '共 ${_drafts.length} 张，已选 $_selectedCount 张。'
                          '取消勾选可以丢弃不准确的卡片。',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      final allSelected = _selectedCount == _drafts.length;
                      _drafts = _drafts
                          .map((d) => d.copyWith(selected: !allSelected))
                          .toList();
                    }),
                    child: Text(
                      _selectedCount == _drafts.length ? '全不选' : '全选',
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                itemCount: _drafts.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, i) => _DraftTile(
                  draft: _drafts[i],
                  onToggle: () => setState(() {
                    _drafts[i] = _drafts[i].copyWith(selected: !_drafts[i].selected);
                  }),
                  onEdit: () => _editDraft(i),
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _saving ? null : () => Navigator.pop(context),
                      child: const Text('稍后再说'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      onPressed:
                          (_saving || _selectedCount == 0) ? null : _commit,
                      icon: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check),
                      label: Text(
                        _saving ? '写入中…' : '加入复习队列（$_selectedCount）',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editDraft(int index) async {
    final draft = _drafts[index];
    final qController = TextEditingController(text: draft.question);
    final aController = TextEditingController(text: draft.answer);

    final result = await showDialog<CardDraft>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑卡片'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: qController,
                maxLines: 3,
                minLines: 2,
                decoration: const InputDecoration(labelText: '问题'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: aController,
                maxLines: 6,
                minLines: 2,
                decoration: const InputDecoration(labelText: '答案'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              ctx,
              draft.copyWith(
                question: qController.text.trim(),
                answer: aController.text.trim(),
              ),
            ),
            child: const Text('确定'),
          ),
        ],
      ),
    );

    qController.dispose();
    aController.dispose();

    if (result != null && mounted) {
      setState(() => _drafts[index] = result);
    }
  }

  Future<void> _commit() async {
    setState(() => _saving = true);
    try {
      final ai = context.read<AiRepository>();
      final count = await ai.commitCardDrafts(
        noteId: widget.noteId,
        drafts: _drafts,
        model: widget.model,
      );
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已加入 $count 张卡片，可到「复习」页开始学习。')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('写入失败：$e')));
    }
  }
}

class _DraftTile extends StatelessWidget {
  const _DraftTile({
    required this.draft,
    required this.onToggle,
    required this.onEdit,
  });

  final CardDraft draft;
  final VoidCallback onToggle;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: draft.selected
              ? theme.colorScheme.primary.withValues(alpha: 0.5)
              : theme.colorScheme.outlineVariant,
        ),
        color: draft.selected
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.18)
            : null,
      ),
      child: InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: draft.selected,
                onChanged: (_) => onToggle(),
                visualDensity: VisualDensity.compact,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      draft.question,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600, height: 1.5),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      draft.answer,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.5,
                      ),
                    ),
                    if (draft.tags.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        children: draft.tags
                            .map((t) => Text(
                                  '#$t',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.primary,
                                  ),
                                ))
                            .toList(),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                onPressed: onEdit,
                icon: const Icon(Icons.edit_outlined, size: 18),
                tooltip: '编辑',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
