import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';


/// 左滑**露出操作按钮**（置顶 / 删除）的列表项包装。**点了按钮才执行。**
///
/// ## 为什么不是"整条划走就删"
///
/// 以前用的是 `Dismissible`：划到底 → 松手 → 直接删。它的假设是"划开这个动作
/// 本身就是一次明确的意图表达"，但那个假设不成立 —— 横滑太容易误触了
/// （单手拿着手机、列表快速滑动时手指稍微偏一点就会划开），而删除是破坏性的。
///
/// 现在中间多一道"**看到按钮**"：划开 → 露出「置顶 / 删除」→ 点哪一个才做哪一个。
/// 那一眼就是确认，而且不用弹对话框（弹窗比这个重得多，还挡住列表）。
///
/// ## 为什么还保留撤销
///
/// 调用方删完会在底部提示条上留一个「撤销」（`LogBar.action`）。多这一道几乎零
/// 成本，而万一还是点错了，用户有条退路。**两道防线不冲突**：一个是事前看清，
/// 一个是事后可退。
///
/// ## 与长按菜单共存
///
///   · 左滑 → 露出快捷操作（置顶 / 删除）
///   · 长按 → 打开完整菜单（移动、改名、导出…）
///
/// 两者保留各自的位置：左滑是"最常用的一两个动作，顺手做掉"，
/// 长按是"我要做别的"。
class SwipeActions extends StatelessWidget {
  const SwipeActions({
    super.key,
    required this.itemKey,
    required this.onDelete,
    required this.child,
    this.deleteLabel = '删除',
    this.onTogglePin,
    this.pinned = false,
  });

  /// 每一项的唯一 key。
  ///
  /// 必须传：`Slidable` 靠 key 认"哪一行是展开的"，不唯一就会出现
  /// "划开 A，B 跟着动"这种串位。
  final Key itemKey;

  /// 点「删除」时调用（**不是**划开时）。
  final VoidCallback onDelete;

  final Widget child;

  /// 删除按钮上的文字，不同列表可以不同（如「移出目录」）。
  final String deleteLabel;

  /// 非空时才出现「置顶 / 取消置顶」。不给就不显示那一颗（比如某些列表不需要）。
  final VoidCallback? onTogglePin;

  /// 现在是不是**已经置顶**，决定那颗按钮写「置顶」还是「取消置顶」。
  ///
  /// 文案必须跟着状态变：同一个按钮上写死「置顶」的话，已置顶的条目点下去
  /// 用户不知道是"再顶一次"还是"取消"。
  final bool pinned;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasPin = onTogglePin != null;

    return Slidable(
      key: itemKey,
      // 只允许从右往左划：从左往右容易与系统的返回手势冲突
      endActionPane: ActionPane(
        // DrawerMotion：按钮**跟着手指滑出来**（而不是原地淡入），
        // 划多少露多少，手感上和"把抽屉拉开"一致。
        motion: const DrawerMotion(),
        // 露出宽度按按钮个数给：一颗 25%，两颗 50%（两个 25% 的资料位）。
        // 给死了会让按钮被压扁或露不满。
        extentRatio: hasPin ? 0.5 : 0.25,
        children: [
          if (hasPin)
            SlidableAction(
              onPressed: (_) => onTogglePin!(),
              icon: pinned ? Icons.push_pin : Icons.push_pin_outlined,
              label: pinned ? '取消置顶' : '置顶',
              backgroundColor: scheme.secondaryContainer,
              foregroundColor: scheme.onSecondaryContainer,
            ),
          SlidableAction(
            onPressed: (_) => onDelete(),
            icon: Icons.delete_outline,
            label: deleteLabel,
            backgroundColor: scheme.errorContainer,
            foregroundColor: scheme.onErrorContainer,
          ),
        ],
      ),
      child: child,
    );
  }
}

/// 把列表包一层，让"划开一行"时**自动收起其它行**。
///
/// 不包也能用，只是可能出现好几行同时敞着 —— 那看着像列表坏了。
/// 所以列表外面套一下这个就行（`flutter_slidable` 自带的协调器）。
class SwipeActionsScope extends StatelessWidget {
  const SwipeActionsScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      SlidableAutoCloseBehavior(child: child);
}
