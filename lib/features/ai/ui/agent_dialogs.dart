import 'package:flutter/material.dart';

import '../../../core/theme/dimens.dart';
import '../domain/ask_user.dart';


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
    // ⚠️ 选择题里「自己写的那句」**也算答案**。以前只认选项，导致用户看不上
    // 任何一条、心里有别的想法时，唯一的出路是「取消」—— 而取消在语义上是
    // **拒绝**，模型会当成"他不做这件事"，那是两回事。
    final typed = _text.text.trim().isNotEmpty;
    if (t == AskType.singleChoice) return _picked.length == 1 || typed;
    if (t == AskType.multipleChoice) return _picked.isNotEmpty || typed;
    return true; // confirm：两个按钮各自直接提交
  }

  void _submit() {
    final t = widget.request.type;
    switch (t) {
      case AskType.text:
        _finish(AskResult.input(_text.text.trim()));
      case AskType.singleChoice:
      case AskType.multipleChoice:
        final typed = _text.text.trim();
        _finish(AskResult.choice(
          _picked.toList(),
          typed: typed.isEmpty ? null : typed,
        ));
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
        final multi = req.type == AskType.multipleChoice;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.options.isEmpty)
              // 没选项时**不能**显示一个空列表让用户干瞪眼 —— 直接让他写，
              // 输入框就在下面（以前这里写的是"可以取消，然后用一句话告诉我"，
              // 那等于逼用户先取消一次，而取消在语义上是**拒绝**）
              Text(
                '没有找到可选项。直接在下面写一句告诉我该怎么做。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              )
            else
              // 选项区可滚（多了不至于把弹层撑爆），输入框固定在下面
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final o in widget.options)
                      _optionTile(theme, o, multi: multi),
                  ],
                ),
              ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _text,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                hintText: multi
                    ? '也可以自己写（一行一条）…'
                    : '也可以不选，直接写你的答案…',
              ),
              // 单选：**文字与选项互斥**。单选的语义就是"一个答案"，
              // 两个同时存在会让模型猜哪个才算数；互斥之后"确定"提交的
              // 必然只有一种。
              onChanged: (v) => setState(() {
                if (!multi && v.trim().isNotEmpty) _picked.clear();
              }),
              onSubmitted: (_) {
                if (_canSubmit) _submit();
              },
            ),
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
          // 单选互斥的另一半：选了选项就把刚写的那句清掉
          //（不清的话两者会一起提交上去，模型得猜哪个算）
          _text.clear();
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
