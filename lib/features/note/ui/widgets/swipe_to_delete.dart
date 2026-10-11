import 'package:flutter/material.dart';

import '../../../../core/theme/dimens.dart';

/// 支持**左滑删除**的列表项包装。
///
/// ## 为什么用"乐观删除 + 撤销"而不是二次确认
///
/// 左滑这个手势本身就是一次明确的意图表达——用户已经划开、看到红色的
/// 删除按钮、再松开。再弹一个对话框问"确定删除吗"是多余的一步。
///
/// 但删除确实是破坏性的，所以给**撤销**：删掉之后在底部提示条上留一个
/// 「撤销」，点一下就恢复。这样既快又不怕手滑，比"先问再删"体验好得多。
///
/// 撤销由调用方实现（把 [onDelete] 里的 noteId 拿去恢复），
/// 因为这个组件不该知道笔记是怎么存的。
///
/// ## 与长按菜单共存
///
/// 左滑删除与长按弹菜单是两套独立手势，互不冲突：
///   · 左滑 → 删除
///   · 长按 → 打开完整的操作菜单（移动、置顶等）
///
/// 两者都保留，因为它们的用途不同：左滑是"快速清掉"，
/// 长按是"我要做别的操作"。
class SwipeToDelete extends StatelessWidget {
  const SwipeToDelete({
    super.key,
    required this.itemKey,
    required this.onDelete,
    required this.child,
    this.deleteLabel = '删除',
  });

  /// 每一项的唯一 key。
  ///
  /// **必须传**：`Dismissible` 要求 key 在列表里唯一，
  /// 否则删除一项后会串位（划掉 A 结果 B 消失）。
  final Key itemKey;

  /// 划到底时调用。
  final VoidCallback onDelete;

  final Widget child;

  /// 背景上的文字，不同列表可以不同（如"移出目录"）
  final String deleteLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Dismissible(
      key: itemKey,
      // 只允许从右往左划：从左往右容易与系统的返回手势冲突
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDelete(),
      background: Container(
        color: scheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.delete_outline, color: scheme.onErrorContainer),
            const SizedBox(width: AppSpacing.sm),
            Text(
              deleteLabel,
              style: TextStyle(
                color: scheme.onErrorContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
      child: child,
    );
  }
}
