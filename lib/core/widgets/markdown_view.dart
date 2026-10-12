import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../theme/dimens.dart';

/// **全项目唯一的 Markdown 渲染入口**。
///
/// 页面里**不要**直接 `new GptMarkdown(...)`。理由不是"少写几个参数好看"，
/// 而是有三个开关必须每个入口都一致，散着写迟早漏一处：
///
/// 1. `useDollarSignsForLatex: true` —— gpt_markdown **默认只认 LaTeX 原生
///    分隔符**（`\(…\)` / `\[…\]`），`$…$` / `$$…$$` 是关着的。用户在笔记里
///    写的是后者（这也是 AI 输出的习惯写法），漏了这个开关公式就退化成
///    一堆带美元符号的普通文本 —— 而且**不报错**，只是"看起来不对"。
/// 2. **正文里的图片不加载**（见 [_imageAsText]）。这条是隐私要求，不是样式
///    偏好：漏一个入口就等于开了一个"打开笔记就向第三方发请求"的口子。
/// 3. 字号缩放（[fontScale]）与系统字号要**一起**生效，不能二选一。
///
/// 顺带的好处：以后换渲染库，改的是这一个文件，而不是四个页面。
///
/// 用 gpt_markdown 而不是 flutter_markdown：`flutter_markdown` 不认 `$` / `$$`
/// （数学公式显示不出来），且已被官方标记 discontinued。`gpt_markdown` 面向
/// AI 输出场景：内置 LaTeX、代码高亮、表格对齐、任务列表、流式增量渲染，
/// 且**自带** `val_latex_flutter`，不需要额外的 `flutter_math_fork`。
///
/// ## 选择与复制
///
/// gpt_markdown 没有 `selectable` 参数，选中能力来自外层包一层
/// [SelectionArea] —— 所以默认 [selectable] 为 true 时由这里包好，
/// 调用方不用管。代码块的"复制"按钮是它内置的，也不用额外接。
class MarkdownView extends StatelessWidget {
  const MarkdownView(
    this.text, {
    super.key,
    this.fontScale = 1.0,
    this.selectable = true,
    this.onLinkTap,
    this.textAlign,
  });

  /// Markdown 原文。
  ///
  /// 公开出来是为了让测试能断言"这一片渲染的是哪段原文"
  /// （阅读视图按片渲染，片与片之间不能串）。
  final String text;

  /// 用户设置的字号倍率（阅读设置里的那一档）。
  ///
  /// 它**不是**系统字号：两者相乘才是最终倍率，见 [_scalerOf]。
  final double fontScale;

  /// 是否允许长按选中 / 复制。默认开。
  ///
  /// 关掉只用在"这块文字不该被选中"的地方（例如卡片上的预览）。
  final bool selectable;

  /// 链接被点击时。null = 点了不做事（**不弹浏览器、不发任何请求**）。
  ///
  /// 刻意不给一个"默认打开浏览器"的行为：那需要 url_launcher，而且会让
  /// 一次误触就把用户带出 App。想跳到哪由调用方自己决定。
  final void Function(String url, String title)? onLinkTap;

  /// 段落对齐。默认跟随环境。
  final TextAlign? textAlign;

  /// 段落基准字号（= Material 3 的 `bodyLarge`，16）。
  ///
  /// 系统字号是按"某个基准字号"换算倍率的，换算时必须拿同一个基准，
  /// 否则用户放大字号后两边的倍率对不上（见 [_scalerOf]）。
  static const baseFontSize = 16.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // 段落样式：正文行高 1.75 是阅读视图定下来的舒适值，别改小。
    // 字号**不在这里写死**：缩放交给 textScaler（见 [_scalerOf]），
    // 两处都乘一遍就会平方放大。
    final body = (theme.textTheme.bodyLarge ??
            const TextStyle(fontSize: baseFontSize))
        .copyWith(height: 1.75);

    final rendered = GptMarkdown(
      text,
      // ⚠️ 别删：默认只认 `\(…\)` / `\[…\]`，用户和 AI 写的是 `$…$` / `$$…$$`
      useDollarSignsForLatex: true,
      style: body,
      textAlign: textAlign,
      textScaler: _scalerOf(context),
      onLinkTap: onLinkTap,
      imageBuilder: _imageAsText,
      styleSheet: GptMarkdownStyleSheet(
        // 引用块：与旧样式保持一致的圆角淡底，否则引用在中文长文里
        // 只剩一根竖线，和正文的区分度太低
        blockQuote: BlockQuoteStyle(
          backgroundColor:
              scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          barRadius: const Radius.circular(AppRadius.card),
        ),
        // 链接用主题色。gpt_markdown 的主题默认是纯蓝，在这个棕色系 App 里
        // 会显得像外来的（而且深浅色下都不对）
        link: LinkStyle(color: scheme.primary),
        // 超长公式**横向滚动**而不是溢出被切断：显示不全的公式比不显示更糟，
        // 用户会以为是自己写错了
        latex: const LatexStyle(scrollBlockHorizontally: true),
      ),
    );

    return selectable ? SelectionArea(child: rendered) : rendered;
  }

  /// 把用户字号倍率与**系统**字号设置合成一个 textScaler。
  ///
  /// 为什么不能直接 `TextScaler.linear(fontScale)`：那会把系统那一档丢掉 ——
  /// 用户在系统里把字体调大（无障碍设置），App 里却纹丝不动。
  ///
  /// 为什么返回 null 而不是 `MediaQuery.textScalerOf(context)`：
  /// gpt_markdown 的 `textScaler` 默认值就是 MediaQuery 的那个，传 null
  /// 等于"照旧"，还能省掉我们自己算错的机会。
  ///
  /// 合成方式：拿系统在 [baseFontSize] 上的倍率 × 用户倍率，再线性应用。
  /// 线性缩放下这是精确的；非线性缩放（Android 14+ 的大字号档）下是近似 ——
  /// 代价是标题的字号在极端档位上可能差一点点，换来的是不用为每个字号单独换算。
  TextScaler? _scalerOf(BuildContext context) {
    if (fontScale == 1.0) return null;
    final system = MediaQuery.textScalerOf(context);
    final factor = system.scale(baseFontSize) / baseFontSize * fontScale;
    return TextScaler.linear(factor);
  }

  /// 正文里的图片**不加载**，只把 URL 当文本显示出来。
  ///
  /// 这是隐私决定，不是能力问题：渲染 `![](url)` 意味着打开一篇笔记就向第三方
  /// 服务器发请求，暴露 IP 与打开时间 —— 和"数据只在你设备上"的定位直接冲突。
  /// 另外图床挂了、对方删了都会变成破图，而且**用户收不到任何提示**；从小红书/
  /// 微信一类站点复制的链接还带防盗链，根本加载不出来。
  ///
  /// 所以这里覆盖成"把 URL 当文本显示"：**不渲染 = 不发任何请求**。
  /// 用户想看图就选中 URL 自己打开。
  ///
  /// ⚠️ 代价：gpt_markdown 的 `imageBuilder` 只给 `url` 和 `WxH` 尺寸，
  /// **拿不到 alt 文字**，所以 `![说明](url)` 里的"说明"不再显示。用一段 alt
  /// 文字换"绝不发请求"，这笔账划算。
  ///
  /// 注：**裸 URL**（不带 `![]()` 的）走的是链接语法，不受这里影响。
  ///
  /// 这个 builder 在**所有** MarkdownView 上生效（阅读视图、卡片详情、AI 回答）：
  /// 必须如此 —— 只在笔记阅读视图挡图片的话，卡片详情页会是直接渲染，同一个
  /// App 里两种行为，那条隐私规则就只在半个产品里成立。
  static Widget _imageAsText(
    BuildContext context,
    String url,
    double? width,
    double? height,
  ) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: AppRadius.cardRadius,
      ),
      child: SelectableText(
        url,
        style: theme.textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
          color: theme.colorScheme.primary,
          fontSize: 13,
        ),
      ),
    );
  }
}
