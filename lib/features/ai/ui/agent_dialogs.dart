import 'package:flutter/material.dart';

import '../../../core/theme/dimens.dart';
import '../../../core/util/app_params.dart';
import '../domain/ask_user.dart';
import '../domain/tool_executor.dart';

/// 「要不要这么做」的确认层（《AI接入设计》说的"App 强制拦截"在这里落地）。
///
/// ## 两个不能省的东西
///
/// **① 改前 vs 改后**：用户要看的是"具体改什么"，不是"AI 想改这条笔记"。
/// 只给一句话的话，他只能盲点「允许」。
///
/// **② 删除的措辞**：`strong == true` 时按钮改成红色「删除」，
/// 摘要里也带着"删了就找不回来"。普通确认框的「确定」太容易被顺手点掉。
///
/// 重复点击靠 [_once] 挡住：用户手快点两下不该执行两次。
Future<bool> showToolConfirm(BuildContext context, ToolConfirmRequest req) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false, // 点外面不算同意；必须明确选
    builder: (ctx) => _ToolConfirmDialog(request: req),
  ).then((v) => v ?? false);
}

class _ToolConfirmDialog extends StatefulWidget {
  const _ToolConfirmDialog({required this.request});
  final ToolConfirmRequest request;

  @override
  State<_ToolConfirmDialog> createState() => _ToolConfirmDialogState();
}

class _ToolConfirmDialogState extends State<_ToolConfirmDialog> {
  /// 已经点过了 → 后续点击一律忽略（**只执行一次**）
  bool _once = false;

  void _close(bool value) {
    if (_once) return;
    _once = true;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = widget.request;
    final danger = r.strong;

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            danger ? Icons.warning_amber_rounded : Icons.edit_outlined,
            size: 20,
            color: danger ? theme.colorScheme.error : null,
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(child: Text(r.title)),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(r.summary, style: theme.textTheme.bodyMedium),
            if (r.warning != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Container(
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer,
                  borderRadius: AppRadius.cardRadius,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, size: 16),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: Text(r.warning!, style: theme.textTheme.bodySmall),
                    ),
                  ],
                ),
              ),
            ],
            if (r.before != null && r.after != null) ...[
              const SizedBox(height: AppSpacing.md),
              _DiffBlock(
                label: '改前',
                text: r.before!,
                color: theme.colorScheme.surfaceContainerHighest,
              ),
              const SizedBox(height: AppSpacing.xs),
              _DiffBlock(
                label: '改后',
                text: r.after!,
                color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
              ),
            ] else if (r.before != null) ...[
              const SizedBox(height: AppSpacing.md),
              _DiffBlock(
                label: '内容',
                text: r.before!,
                color: theme.colorScheme.surfaceContainerHighest,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _close(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => _close(true),
          style: danger
              ? FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                )
              : null,
          child: Text(danger ? '删除' : '允许'),
        ),
      ],
    );
  }
}

/// 一段"改前/改后"的文本块。太长时截断并标注，别把弹层撑成一整篇文章。
class _DiffBlock extends StatelessWidget {
  const _DiffBlock({
    required this.label,
    required this.text,
    required this.color,
  });

  final String label;
  final String text;
  final Color color;

  static const _maxChars = AgentLimits.confirmDiffMaxChars;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final clipped =
        text.length > _maxChars ? '${text.substring(0, _maxChars)}\n…（已截断）' : text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 2),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 160),
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            color: color,
            borderRadius: AppRadius.cardRadius,
          ),
          child: SingleChildScrollView(
            child: Text(clipped, style: theme.textTheme.bodySmall),
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// askUser 的答题层
// ============================================================================

/// 弹出答题界面，返回用户的选择。
///
/// 永远可以取消（返回 [AskResult.cancelled]）："拒绝"是合法回答，
/// 也是用户从挂起状态脱身的唯一出口 —— 没有它，用户关掉 App 就永久挂起。
Future<AskResult> showAskSheet(
  BuildContext context,
  AskRequest request,
  List<AskOption> options,
) {
  return showModalBottomSheet<AskResult>(
    context: context,
    isScrollControlled: true,
    isDismissible: false, // 必须明确作答或取消；随手一划不算
    builder: (ctx) => _AskSheet(request: request, options: options),
  ).then((v) => v ?? AskResult.cancelled());
}

class _AskSheet extends StatefulWidget {
  const _AskSheet({required this.request, required this.options});
  final AskRequest request;
  final List<AskOption> options;

  @override
  State<_AskSheet> createState() => _AskSheetState();
}

class _AskSheetState extends State<_AskSheet> {
  final _text = TextEditingController();
  final _picked = <String>{};
  bool _once = false;

  @override
  void initState() {
    super.initState();
    if (widget.request.type == AskType.text &&
        widget.request.defaultValue != null) {
      _text.text = widget.request.defaultValue!;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _finish(AskResult result) {
    if (_once) return;
    _once = true;
    Navigator.of(context).pop(result);
  }

  bool get _canSubmit {
    final t = widget.request.type;
    if (t == AskType.text) return _text.text.trim().isNotEmpty;
    if (t == AskType.singleChoice) return _picked.length == 1;
    if (t == AskType.multipleChoice) return _picked.isNotEmpty;
    return true; // confirm：两个按钮各自直接提交
  }

  void _submit() {
    final t = widget.request.type;
    switch (t) {
      case AskType.text:
        _finish(AskResult.input(_text.text.trim()));
      case AskType.singleChoice:
      case AskType.multipleChoice:
        _finish(AskResult.choice(_picked.toList()));
      case AskType.confirm:
        _finish(AskResult.confirm(true));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final req = widget.request;
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(req.question, style: theme.textTheme.titleMedium),
              const SizedBox(height: AppSpacing.md),
              Flexible(child: _body(theme)),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  TextButton(
                    onPressed: () => _finish(AskResult.cancelled()),
                    child: const Text('取消'),
                  ),
                  const Spacer(),
                  if (req.type == AskType.confirm) ...[
                    OutlinedButton(
                      onPressed: () => _finish(AskResult.confirm(false)),
                      child: const Text('不用'),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    FilledButton(
                      onPressed: () => _finish(AskResult.confirm(true)),
                      child: const Text('好'),
                    ),
                  ] else
                    FilledButton(
                      onPressed: _canSubmit ? _submit : null,
                      child: const Text('确定'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(ThemeData theme) {
    final req = widget.request;
    switch (req.type) {
      case AskType.text:
        return TextField(
          controller: _text,
          autofocus: true,
          maxLines: 4,
          minLines: 1,
          decoration: const InputDecoration(
            hintText: '输入你的回答…',
            border: OutlineInputBorder(),
          ),
          // ⚠️ 必须重建：「确定」的可用性取决于输入内容。
          // 少了这一句，用户打完字按钮还是灰的，根本提交不了。
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) {
            if (_canSubmit) _submit();
          },
        );

      case AskType.singleChoice:
      case AskType.multipleChoice:
        if (widget.options.isEmpty) {
          // 没选项时**不能**显示一个空列表让用户干瞪眼
          return Text(
            '没有找到可选项。可以取消，然后用一句话告诉我该怎么做。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          );
        }
        return ListView(
          shrinkWrap: true,
          children: [
            for (final o in widget.options)
              _optionTile(theme, o, multi: req.type == AskType.multipleChoice),
          ],
        );

      case AskType.confirm:
        return const SizedBox.shrink();
    }
  }

  Widget _optionTile(ThemeData theme, AskOption o, {required bool multi}) {
    final on = _picked.contains(o.id);
    return InkWell(
      onTap: () => setState(() {
        if (multi) {
          on ? _picked.remove(o.id) : _picked.add(o.id);
        } else {
          _picked
            ..clear()
            ..add(o.id);
        }
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Row(
          children: [
            Icon(
              multi
                  ? (on ? Icons.check_box : Icons.check_box_outline_blank)
                  : (on ? Icons.radio_button_checked : Icons.radio_button_off),
              size: 20,
              color: on ? theme.colorScheme.primary : null,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(o.label, style: theme.textTheme.bodyMedium),
                  if (o.description != null)
                    Text(
                      o.description!,
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
