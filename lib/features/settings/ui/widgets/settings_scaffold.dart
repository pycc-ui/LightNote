import 'package:flutter/material.dart';

import '../../../../core/theme/dimens.dart';

/// 设置子页的统一骨架。
///
/// 为什么抽出来：设置被拆成多个子页后，每个子页都会重复
/// 「Scaffold + AppBar + 分组标题 + 列表」。抽成一个骨架能让
/// 各页只关心自己的内容，也保证所有子页的间距/标题样式一致。
///
/// 用法：
/// ```dart
/// SettingsSubPage(
///   title: '外观',
///   children: [
///     SettingsGroup(children: [ ListTile(...), ListTile(...) ]),
///     SettingsGroupHeader('说明'),
///     SettingsNote('一段解释文字'),
///   ],
/// )
/// ```
class SettingsSubPage extends StatelessWidget {
  const SettingsSubPage({
    required this.title,
    required this.children,
    this.bottomPadding = AppSpacing.xl,
    super.key,
  });

  final String title;
  final List<Widget> children;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: EdgeInsets.only(bottom: bottomPadding),
        children: children,
      ),
    );
  }
}

/// 一个设置分组：视觉上把若干 ListTile 归到一起。
///
/// 用 [Card] 而不是纯列表：设置项被拆到子页后，
/// 分组之间的边界变得重要（一个子页里可能有两三个分组）。
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({required this.children, this.padding, super.key});

  final List<Widget> children;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      child: Padding(
        padding: padding ?? const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

/// 分组标题（子页里的小节名）
class SettingsGroupHeader extends StatelessWidget {
  const SettingsGroupHeader(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md + AppSpacing.xs,
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.xs,
      ),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// 一段说明文字（替代原来把长解释塞进 ListTile.subtitle 的做法）
class SettingsNote extends StatelessWidget {
  const SettingsNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md + AppSpacing.xs,
        AppSpacing.xs,
        AppSpacing.md + AppSpacing.xs,
        AppSpacing.sm,
      ),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          height: 1.6,
        ),
      ),
    );
  }
}

/// 需要引起注意的说明（错误色底）
class SettingsAlertNote extends StatelessWidget {
  const SettingsAlertNote({
    required this.title,
    required this.body,
    this.severe = false,
    super.key,
  });

  final String title;
  final String body;

  /// true 用错误色（数据有丢失风险这类），false 用中性底色
  final bool severe;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: severe
              ? theme.colorScheme.errorContainer
              : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w700,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              body,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}
