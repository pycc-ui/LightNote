import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/db/app_database.dart';
import '../../../core/theme/dimens.dart';
import '../../note/data/notebook_repository.dart';
import '../domain/agent_workspace.dart';

/// 选择 AI 的工作区：**不选择 / 全体空间 / 选择笔记库**。
///
/// 不用通用的单库选择器：`showNotebookPicker` 只返回一个 id，而工作区要能表达
/// 三件事：不选择、全体、以及"挑了若干库 + 要不要带轻笔记"。硬塞进单库选择器的话，
/// 「全体空间」就没地方放。
///
/// 返回值：按「确定」时返回新的 [AgentWorkspace]；取消返回 null。
Future<AgentWorkspace?> showWorkspaceSheet(
  BuildContext context, {
  required AgentWorkspace current,
}) {
  return showModalBottomSheet<AgentWorkspace>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _WorkspaceSheet(current: current),
  );
}

class _WorkspaceSheet extends StatefulWidget {
  const _WorkspaceSheet({required this.current});

  final AgentWorkspace current;

  @override
  State<_WorkspaceSheet> createState() => _WorkspaceSheetState();
}

class _WorkspaceSheetState extends State<_WorkspaceSheet> {
  late WorkspaceMode _mode = widget.current.mode;
  late final Set<String> _picked = {...widget.current.notebookIds};
  late bool _unfiled = widget.current.includeUnfiled;

  AgentWorkspace get _result => AgentWorkspace(
        mode: _mode,
        // 非 pick 模式不保留选中项：从 all 切回 pick 时留着旧选择，
        // 会让人以为"我刚才勾的那些还在"
        notebookIds:
            _mode == WorkspaceMode.pick ? _picked.toList() : const [],
        includeUnfiled: _mode == WorkspaceMode.pick && _unfiled,
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                0,
                AppSpacing.md,
                AppSpacing.xs,
              ),
              child: Text('工作区', style: theme.textTheme.titleMedium),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Text(
                '决定 AI 能看到哪些笔记 —— 搜索和列笔记都只在这个范围内。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),

            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  RadioGroup<WorkspaceMode>(
                    groupValue: _mode,
                    onChanged: (v) =>
                        setState(() => _mode = v ?? WorkspaceMode.none),
                    child: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        RadioListTile<WorkspaceMode>(
                          value: WorkspaceMode.none,
                          title: Text('不选择'),
                          subtitle: Text('AI 看不到任何笔记，只能看你手动附上的文件'),
                        ),
                        RadioListTile<WorkspaceMode>(
                          value: WorkspaceMode.all,
                          title: Text('全体空间'),
                          subtitle: Text('全部笔记库 + 我的轻笔记'),
                        ),
                        RadioListTile<WorkspaceMode>(
                          value: WorkspaceMode.pick,
                          title: Text('选择笔记库'),
                          subtitle: Text('可多选，也可以只带上「我的轻笔记」'),
                        ),
                      ],
                    ),
                  ),

                  // 只有「选择笔记库」才展开清单 —— 前两项已经定死了范围，
                  // 再显示清单只会让人以为还能改
                  if (_mode == WorkspaceMode.pick) ...[
                    const Divider(height: 1),
                    StreamBuilder<List<Notebook>>(
                      stream: context.watch<NotebookRepository>().watchAll(),
                      builder: (context, snap) {
                        final list = snap.data ?? const <Notebook>[];
                        if (list.isEmpty) {
                          return const Padding(
                            padding: EdgeInsets.all(AppSpacing.md),
                            child: Text('还没有笔记库。先建一个，或改选「全体空间」。'),
                          );
                        }
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final nb in list)
                              CheckboxListTile(
                                value: _picked.contains(nb.id),
                                onChanged: (on) => setState(() {
                                  if (on == true) {
                                    _picked.add(nb.id);
                                  } else {
                                    _picked.remove(nb.id);
                                  }
                                }),
                                title: Text(nb.name),
                                dense: true,
                              ),
                          ],
                        );
                      },
                    ),
                    CheckboxListTile(
                      value: _unfiled,
                      onChanged: (on) => setState(() => _unfiled = on ?? false),
                      title: const Text('我的轻笔记'),
                      subtitle: const Text('还没归入任何笔记库的那些'),
                      dense: true,
                    ),
                  ],
                ],
              ),
            ),

            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(_result),
                child: const Text('确定'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
