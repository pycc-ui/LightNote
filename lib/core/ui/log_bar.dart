import 'package:flutter/material.dart';

import '../theme/dimens.dart';

/// 全 App 统一的日志条，替代散落各页的 ScaffoldMessenger 直调。
///
/// 所有提示 3 秒后自动关闭；唯一例外是 [LogBar.busy]，
/// 它表示任务进行中，必须由句柄 [LogBarHandle.close] 收起。
///
/// - [LogBar.info]    普通提示
/// - [LogBar.success] 成功反馈
/// - [LogBar.error]   失败/异常反馈
/// - [LogBar.action]  带操作按钮的提示
/// - [LogBar.busy]    长驻任务提示，返回句柄，结束后 [LogBarHandle.close]
abstract final class LogBar {
  static const Duration _defaultDuration = Duration(seconds: 3);

  static void info(BuildContext context, String message) =>
      _show(context, message);

  static void success(BuildContext context, String message) {
    final scheme = Theme.of(context).colorScheme;
    _show(context, message,
        icon: Icons.check_circle_outline, color: scheme.primary);
  }

  static void error(BuildContext context, String message) {
    final scheme = Theme.of(context).colorScheme;
    _show(context, message,
        icon: Icons.error_outline, color: scheme.error);
  }

  /// 点按钮会自动收起提示；[onAction] 为空则仅收起。
  static void action(
    BuildContext context,
    String message, {
    required String actionLabel,
    VoidCallback? onAction,
  }) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: _defaultDuration,
        content: Text(message),
        action: SnackBarAction(
          label: actionLabel,
          onPressed: onAction ?? () {},
        ),
      ),
    );
  }

  /// 耗时任务的长驻提示（带转圈），完成后调用句柄的 [LogBarHandle.close]。
  static LogBarHandle busy(BuildContext context, String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(minutes: 5),
        content: Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
    return LogBarHandle._(messenger);
  }

  static void _show(
    BuildContext context,
    String message, {
    IconData? icon,
    Color? color,
  }) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: _defaultDuration,
        content: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: color),
              const SizedBox(width: AppSpacing.sm),
            ],
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }
}

/// [LogBar.busy] 返回的句柄，任务结束后调用 [close]。
final class LogBarHandle {
  final ScaffoldMessengerState _messenger;

  const LogBarHandle._(this._messenger);

  /// 收起长驻提示。
  void close() => _messenger.hideCurrentSnackBar();
}
