import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/dimens.dart';
import '../../../ai/data/deepseek_config.dart';
import '../../../ai/domain/ai_repository.dart';
import '../widgets/settings_scaffold.dart';

/// 「查看余额」：进入时调用 DeepSeek 的 `/user/balance`，展示各币种余额。
///
/// 只读页面，不改任何设置。失败不弹提示，就地显示原因 + 重试按钮——
/// 用户点进来就是为了看余额，把失败原因放在他是最有用的。
class BalancePage extends StatefulWidget {
  const BalancePage({super.key});

  @override
  State<BalancePage> createState() => _BalancePageState();
}

class _BalancePageState extends State<BalancePage> {
  bool _loading = true;
  AccountBalance? _balance;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _balance = null;
    });
    try {
      final balance = await context.read<AiRepository>().fetchBalance();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _balance = balance;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SettingsSubPage(
      title: '账户余额',
      children: [
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.xxl),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null) ...[
          const SettingsGroupHeader('查询失败'),
          SettingsAlertNote(
            title: '没能取到余额',
            body: _error!,
            severe: true,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: FilledButton(
              onPressed: _load,
              child: const Text('重试'),
            ),
          ),
        ] else if (_balance != null) ...[
          if (!_balance!.isAvailable)
            const SettingsAlertNote(
              title: '账户不可用',
              body: '余额可能已耗尽，AI 请求会以「账户余额不足」失败。'
                  '请到 DeepSeek 平台充值后再试。',
              severe: true,
            ),
          if (_balance!.infos.isEmpty)
            const SettingsNote('接口没有返回余额信息。'),
          for (final info in _balance!.infos) _balanceCard(theme, info),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.md,
              0,
            ),
            child: OutlinedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('刷新'),
            ),
          ),
        ],
        const SettingsNote(
          '余额来自 DeepSeek 的 `/user/balance` 接口，仅供参考，'
          '实际可用金额以官方账单为准。',
        ),
      ],
    );
  }

  Widget _balanceCard(ThemeData theme, BalanceInfo info) {
    return SettingsGroup(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${info.totalBalance} ${info.currency}',
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 2),
              Text(
                '总余额',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const Divider(height: AppSpacing.lg),
              _amountRow(theme, '充值余额', info.toppedUpBalance, info.currency),
              if (!_isZero(info.grantedBalance)) ...[
                const SizedBox(height: AppSpacing.xs),
                _amountRow(theme, '赠送余额', info.grantedBalance, info.currency),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 金额字符串是否为零。接口可能给 `0` / `0.00` / `0.0` 几种写法。
  static bool _isZero(String amount) =>
      (double.tryParse(amount.trim()) ?? 0) == 0;

  Widget _amountRow(
    ThemeData theme,
    String label,
    String amount,
    String currency,
  ) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: theme.textTheme.bodyMedium),
        Text(
          '$amount $currency',
          style: theme.textTheme.bodyMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}
