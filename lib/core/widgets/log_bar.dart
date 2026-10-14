import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/dimens.dart';

/// 全 App 统一的日志条，替代散落各页的 ScaffoldMessenger 直调。
///
/// | 方法 | 什么时候用 | 自动消失 |
/// |---|---|---|
/// | [LogBar.info] | 中性反馈：确认、引导。没有"成功/失败"倾向 | 是（3 秒） |
/// | [LogBar.success] | 操作**做成了** | 是（3 秒） |
/// | [LogBar.warn] | 操作**没做成但不是错误**：结果为空、风控拦截 | 是（4 秒） |
/// | [LogBar.error] | **失败**：异常、或挡住了用户想做的事 | 是（3 秒） |
/// | [LogBar.action] | 带按钮，或内容必须被看清 | 默认否 |
/// | [LogBar.busy] | 耗时任务进行中 | 否，由句柄收起 |
///
/// 怎么选：
///   · 用户想做的事**被挡住了** → error（例：没配 API Key）
///   · 做完了但**结果不合预期** → warn（例：没能生成出卡片）
///   · **做成了** → success
///   · 纯粹告知、无所谓成败 → info（例：正文为空，这是引导不是错）
///
/// 级别的意义不只是配色：error/warn 会带图标，用户扫一眼就能分辨
/// "这是出问题了"还是"这只是提示"。
///
/// ## 一、为什么每个 SnackBar 都要显式写 `persist`
///
/// 不显式写会踩到一个坑：**带操作按钮的提示弹出来永远不消失**。
///
/// 原因在 Flutter 源码里（`snack_bar.dart`）：
///
/// ```dart
/// persist = persist ?? action != null;      // 有 action 就默认 persist = true
/// ```
///
/// 而超时定时器是这么写的（`scaffold.dart`）：
///
/// ```dart
/// _snackBarTimer = Timer(snackBar.duration, () {
///   if (snackBar.persist) return;           // 直接返回，永不超时
///   hideCurrentSnackBar(reason: SnackBarClosedReason.timeout);
/// });
/// ```
///
/// 所以只要传了 [SnackBarAction]，`duration` 就被**彻底忽略**。
/// 这里统一显式指定，让行为可预期、不依赖 Flutter 的默认值。
///
/// 顺带说明：Flutter 文档提到「TalkBack/VoiceOver 开启时带 action 的
/// SnackBar 不会超时」，说的其实就是上面这个 persist 默认值，
/// 并不是另外去读 `MediaQuery.accessibleNavigation`。
///
/// ## 二、`action` 为什么默认常驻，而 `info` 不
///
/// 两者用途不同：
///
/// - [LogBar.action] 用于「需要用户处理」的内容——有按钮要点（撤销），
///   或者内容本身重要（比如"已从备份恢复，旧数据留档在 X"）。
///   这类提示自动消失会让用户错过，所以默认 `persist: true`，
///   要它自动走就显式传 `persist: false`。
/// - [LogBar.info] 之类是纯反馈，错过了顶多再操作一次，所以 3 秒自动走。
///
/// ## 三、耗时任务期间的提示会被压掉
///
/// ScaffoldMessenger 是**排队**的：前一条没走完，后一条一直等。
/// 而 AI 整理/生成卡片动辄几十秒，期间用户很容易再点几下，
/// 弹出若干"正文为空""还没配置 Key"之类的提示——
/// 它们全都堆在队列里，**任务结束后才开始一条条播放**，
/// 用户看到的是过期的、已经没意义的提示在刷屏。
///
/// 所以任务进行中（有 [LogBar.busy] 在）时，普通提示会**直接丢弃**
/// 并打日志。这类提示本来就是"当下告诉你"的，过期即无价值。
abstract final class LogBar {
  static const Duration _defaultDuration = Duration(seconds: 3);

  /// 当前是否有 [LogBar.busy] 在显示。
  static bool _busyActive = false;

  /// 供调用方判断"现在弹提示会不会被压掉"。
  static bool get isBusy => _busyActive;

  static void info(BuildContext context, String message) =>
      _show(context, message);

  static void success(BuildContext context, String message) {
    final scheme = Theme.of(context).colorScheme;
    _show(context, message,
        icon: Icons.check_circle_outline, color: scheme.primary);
  }

  /// 操作没做成，但**不是错误**——结果为空、被规则拦下之类。
  ///
  /// 比 [info] 多一个图标，让用户能看出"这次没成"而不是"已完成"。
  static void warn(BuildContext context, String message) {
    final scheme = Theme.of(context).colorScheme;
    _show(context, message,
        icon: Icons.info_outline,
        color: scheme.tertiary,
        // 比 info 多停一秒：这类消息用户需要看清"为什么没成"
        duration: const Duration(seconds: 4));
  }

  /// 失败/异常反馈。
  ///
  /// [showWhileBusy] 默认 true：**失败信息必须能穿过 busy 被看到**。
  /// 否则「AI 整理失败」会被"任务进行中"的过滤规则丢掉，
  /// 用户只看到转圈一直转，不知道已经失败了。
  static void error(
    BuildContext context,
    String message, {
    bool showWhileBusy = true,
  }) {
    final scheme = Theme.of(context).colorScheme;
    _show(context, message,
        icon: Icons.error_outline,
        color: scheme.error,
        showWhileBusy: showWhileBusy);
  }

  /// 带操作按钮 / 需要被看到的提示。
  ///
  /// [persist] 为 true（默认）时不会自动消失，要用户点按钮或手动关掉。
  /// 纯"撤销"类的一步操作可以传 false，让它 3 秒后自己走。
  ///
  /// [showWhileBusy] 为 true 时，即使有 [LogBar.busy] 在也照样排队显示。
  /// 失败信息会用这个，避免"任务失败了却什么都没说"。
  static void action(
    BuildContext context,
    String message, {
    required String actionLabel,
    VoidCallback? onAction,
    bool persist = true,
    bool showWhileBusy = false,
  }) {
    _show(
      context,
      message,
      persist: persist,
      showWhileBusy: showWhileBusy,
      action: SnackBarAction(
        label: actionLabel,
        onPressed: () => onAction?.call(),
      ),
    );
  }

  /// 耗时任务的长驻提示（带转圈），必须用返回的句柄 [LogBarHandle.close] 收起。
  ///
  /// 调用方务必用 `try / finally` 包起来，保证任何返回路径都会收起：
  ///
  /// ```dart
  /// final busy = LogBar.busy(context, '正在整理…');
  /// try {
  ///   await doWork();
  /// } finally {
  ///   busy.close();   // 即使中途 return / 抛异常也会执行
  /// }
  /// ```
  ///
  /// 不这么写就会泄漏：busy 是常驻的，一旦某条 `return` 越过了
  /// `close()`，那条转圈提示会一直挡在屏幕上（兜底 5 分钟），
  /// 期间所有其它提示都会排队等它。AI 整理与生成卡片两处都出过这个错
  ///（`if (!mounted) return;` 写在 `close()` 之前）。
  static LogBarHandle busy(BuildContext context, String message) {
    final messenger = ScaffoldMessenger.of(context);
    _busyActive = true;
    messenger.showSnackBar(
      SnackBar(
        // 常驻，由句柄收起。duration 只是兜底：
        // 万一 close() 真的没被调用，5 分钟后也能自己走，不至于永久挡住。
        persist: true,
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
    SnackBarAction? action,
    bool persist = false,
    bool showWhileBusy = false,
    Duration? duration,
  }) {
    // 任务进行中的普通提示会被队列压到任务结束之后才播，届时已经没意义了。
    // 直接丢弃并留日志，比让用户看一串过期提示好。
    if (_busyActive && !showWhileBusy) {
      if (kDebugMode) {
        debugPrint('[LogBar] 任务进行中，丢弃提示：$message');
      }
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        // 必须显式指定，见类注释：传了 action 时 Flutter 默认 persist = true
        persist: persist,
        duration: duration ?? _defaultDuration,
        content: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: color),
              const SizedBox(width: AppSpacing.sm),
            ],
            Expanded(child: Text(message)),
          ],
        ),
        action: action,
      ),
    );
  }
}

/// [LogBar.busy] 返回的句柄，任务结束后调用 [close]。
///
/// 用 `try / finally` 保证一定会被调用，否则长驻提示会泄漏。
final class LogBarHandle {
  final ScaffoldMessengerState _messenger;
  bool _closed = false;

  LogBarHandle._(this._messenger);

  /// 收起长驻提示。重复调用无副作用。
  void close() {
    if (_closed) return;
    _closed = true;
    LogBar._busyActive = false;
    if (!_messenger.mounted) return;
    _messenger.hideCurrentSnackBar();
  }
}
