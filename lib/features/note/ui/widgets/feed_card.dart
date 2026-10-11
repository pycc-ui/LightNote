import 'package:flutter/material.dart';

import '../../../../core/theme/dimens.dart';

/// 卡片流里的一张卡片。
///
/// ## 卡片上只有标题
///
/// 早先的版本在卡片上放过"摘要/预览"，结果怎么定义都别扭：
///   · 用正文截取 -> 摘要是"正文的前面部分"，读起来像被截断
///   · 让 AI 单独生成摘要 -> 要维护两个内容字段，还得反复调字数
///
/// 最终简化成：**卡片就是标题（至多 3 行），点进去看正文。**
/// 所以标题必须一个人承担"让人想点进去"的责任——它得是有钩子的一句话，
/// 而不是「间隔重复」这种干标签（提示词里专门强调了这点）。
///
/// ## 高度自适应
///
/// 不再固定 `屏高 × 2/3`。标题 1 行就矮、3 行就高，最多到屏高 2/3。
/// 固定高度会让短标题的卡片留一大片空白，看着"填不满"。
class FeedCard extends StatelessWidget {
  const FeedCard({
    super.key,
    required this.title,
    required this.addedToInbox,
    this.tag,
    this.onTap,
    this.onAddToInbox,
    this.onRemoveFromInbox,
  });

  /// 卡片上唯一显示的文字。至多 3 行，超出省略。
  final String title;

  /// 展示用的短标签（取生成结果的第一个标签）。
  ///
  /// 放在标题下面当一个小 chip：它给用户一个"这条在讲什么"的
  /// 快速定位，又不占用标题那三行的宝贵空间。
  final String? tag;

  /// 是否已经收进「我的轻笔记」。
  ///
  /// **不要传内存里记的状态**：要按数据库的真实情况传（见 InboxPage
  /// 里 `_isAdded` 的说明）。否则用户在笔记库页把它删了，这边还显示
  /// 「已加入」，点也点不动。
  final bool addedToInbox;

  final VoidCallback? onTap;
  final VoidCallback? onAddToInbox;

  /// 已加入时点按钮的行为：从「我的轻笔记」移出。
  final VoidCallback? onRemoveFromInbox;

  /// 卡片高度上限：屏高的 2/3。
  static double maxHeightFor(double screenHeight) {
    final h = screenHeight * kFeedCardHeightRatio;
    return h < kFeedCardMinHeight ? kFeedCardMinHeight : h;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final screenH = MediaQuery.sizeOf(context).height;

    return ConstrainedBox(
      // 上限：标题再长也不超过 2/3 屏（实际由 maxLines 先截住）
      constraints: BoxConstraints(maxHeight: maxHeightFor(screenH)),
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        // 描边：深色模式下卡片与背景色差很小，实测几乎看不出边界。
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.cardRadius,
          side: BorderSide(color: scheme.outlineVariant),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: kFeedCardPadding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              // 用 spaceBetween 把"元信息 + 按钮"推到底部。
              // **不能用 Spacer**：Spacer 是 flex，会把 Column 撑满外层
              // ConstrainedBox 的 maxHeight，于是 1 行标题的卡片也占满
              // 2/3 屏、中间一大片空白（实测踩过）。
              // spaceBetween 在内容本来就矮时不会额外撑高。
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ---- 标题：卡片的全部内容 ----
                Text(
                  title.isEmpty ? '（无标题）' : title,
                  maxLines: kFeedTitleMaxLines,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontSize: kFeedTitleFontSize,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                  ),
                ),

                const SizedBox(height: AppSpacing.sm),
                // 「点开看全文」提示。
                //
                // 卡片上只有标题，必须让用户知道还有下文可看，
                // 否则他会以为这就是全部内容。
                //
                // 标签**不在这里**——它挪到了底部左侧的元信息位
                // （替代原来的「AI 生成」），见下面那段。
                Row(
                  children: [
                    Text(
                      '点开看全文',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: kFeedMetaFontSize,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),

                const SizedBox(height: AppSpacing.md),
                // ---- 底部一行：左标签，右下按钮 ----
                //
                // 用 `spaceBetween` 而不是 `Spacer` 把两端撑开：
                // 只有两个"端点"子项时，spaceBetween 的行为最直白——
                // 第一个贴左、最后一个贴右，中间的空白它来分配。
                // （这块之前用过 `Spacer` + `Flexible`，实测容易出
                // 意外的分配结果，按钮会浮在中间偏左。）
                //
                // `SizedBox(width: double.infinity)` 保证这一行占满
                // 卡片的可用宽度；否则它可能按内容收缩。
                SizedBox(
                  width: double.infinity,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // 左下角只放**标签**，一个词。
                      //
                      // 这里原本交替显示「AI 生成」/「已加入我的轻笔记」，
                      // 但两者都是**关于这条卡片本身**的元信息，而用户
                      // 更想知道的是"它在讲什么"。按钮文案已经能表达
                      // 加入状态了，所以这一格让给标签。
                      //
                      // 没有标签时退回「AI 生成」——那是可靠的兜底，
                      // 也让左下角不会突然空掉。
                      Flexible(
                        child: Text(
                          (tag != null && tag!.isNotEmpty) ? tag! : 'AI 生成',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: kFeedMetaFontSize,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      // 左下角是标签、右下角是这个按钮——按产品要求布局。
                      //
                      // 按钮是个**开关**：未加入时橙色「加入我的轻笔记」，
                      // 加入后变成「从我的轻笔记移出」。早先加入后是禁用
                      // 变灰，用户以为坏了——其实是想撤销的，没有入口。
                      FilledButton.tonalIcon(
                        onPressed: addedToInbox
                            ? onRemoveFromInbox
                            : onAddToInbox,
                        icon: Icon(
                          addedToInbox
                              ? Icons.remove_circle_outline
                              : Icons.bolt_outlined,
                          size: 16,
                        ),
                        label: Text(
                          addedToInbox ? '从我的轻笔记移出' : '加入我的轻笔记',
                        ),
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.md,
                            vertical: AppSpacing.sm,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
