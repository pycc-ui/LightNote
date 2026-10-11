import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/db/app_database.dart';
import '../../../../core/theme/dimens.dart';
import '../../../ai/data/deepseek_config.dart';
import '../widgets/settings_scaffold.dart';

/// 用量与成本：累计估算成本（数据来自 ai_calls 表）。
class UsageSettingsPage extends StatelessWidget {
  const UsageSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: '用量与成本',
      children: [
        const SettingsGroupHeader('累计估算成本'),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: _CostCard(),
        ),
        const SettingsNote(
          '按 DeepSeek 官方公布的价格估算，区分高峰/空闲时段'
          '（空闲时段价格是高峰的一半）。实际扣费以官方账单为准。\n\n'
          '省钱要点：思考模式默认开启且强度为 high，本 App 在轻量任务上'
          '会自动关掉它；批量整理放周末或晚上更便宜。',
        ),
      ],
    );
  }
}

/// 累计成本卡片：数据来自 ai_calls 表
class _CostCard extends StatelessWidget {
  const _CostCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: StreamBuilder<double>(
        stream: context.read<AppDatabase>().watchTotalCostCents(),
        builder: (context, snapshot) {
          final cents = snapshot.data ?? 0;
          return Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      DeepSeekPricing.formatCents(cents),
                      style: theme.textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      '累计估算成本',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '统计范围：本机数据库里记录的每一次 AI 调用。'
                  '清空 AI 历史会把这个数字也归零。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
