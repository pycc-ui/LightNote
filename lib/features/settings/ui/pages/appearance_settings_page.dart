import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/dimens.dart';
import '../../../../core/prefs/preferences_service.dart';
import '../widgets/settings_scaffold.dart';

/// 外观设置：主题、字体大小。
class AppearanceSettingsPage extends StatelessWidget {
  const AppearanceSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final prefs = context.read<PreferencesService>();

    return SettingsSubPage(
      title: '外观',
      children: [
        const SettingsGroupHeader('主题与字体'),
        SettingsGroup(
          children: [
            StreamBuilder<String>(
              stream: prefs.watchThemeMode(),
              builder: (context, snap) {
                final mode = snap.data ?? 'system';
                return ListTile(
                  leading: const Icon(Icons.palette_outlined),
                  title: const Text('主题'),
                  subtitle: Text(themeModeLabel(mode)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _pickTheme(context, prefs, mode),
                );
              },
            ),
            StreamBuilder<double>(
              stream: prefs.watchFontScale(),
              builder: (context, snap) {
                final scale = snap.data ?? 1.0;
                return ListTile(
                  leading: const Icon(Icons.format_size),
                  title: const Text('字体大小'),
                  subtitle: Text(fontScaleLabel(scale)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _pickFontScale(context, prefs, scale),
                );
              },
            ),
          ],
        ),
        const SettingsNote(
          '字体大小只影响笔记正文的编辑与阅读视图，不影响界面其他文字。',
        ),
        const SettingsGroupHeader('预览'),
        const _FontPreview(),
      ],
    );
  }

  static String themeModeLabel(String mode) => switch (mode) {
        'light' => '浅色',
        'dark' => '深色',
        _ => '跟随系统',
      };

  /// 字体大小档位的人类可读标签。
  ///
  /// 放在这里而不是 PreferencesService：它是纯展示逻辑，
  /// 且外观页与预览都要用，跟着页面走比塞进 service 更合适。
  static String fontScaleLabel(double scale) {
    if (scale < 0.9) return '小（${(scale * 100).round()}%）';
    if (scale < 1.05) return '中（100%）';
    if (scale < 1.2) return '大（${(scale * 100).round()}%）';
    return '特大（${(scale * 100).round()}%）';
  }

  Future<void> _pickTheme(
    BuildContext context,
    PreferencesService prefs,
    String current,
  ) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (value, label) in const [
              ('system', '跟随系统'),
              ('light', '浅色'),
              ('dark', '深色'),
            ])
              ListTile(
                leading: Icon(value == current
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked),
                title: Text(label),
                onTap: () => Navigator.pop(ctx, value),
              ),
          ],
        ),
      ),
    );
    if (picked != null) await prefs.writeThemeMode(picked);
  }

  Future<void> _pickFontScale(
    BuildContext context,
    PreferencesService prefs,
    double current,
  ) async {
    var temp = current;
    final result = await showModalBottomSheet<double>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, 0, AppSpacing.md, AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('正文字体大小', style: Theme.of(ctx).textTheme.titleMedium),
                const SizedBox(height: AppSpacing.md),
                Text(
                  '示例文字：轻笔记 LightNote',
                  style: TextStyle(fontSize: 16 * temp),
                ),
                Slider(
                  value: temp,
                  min: 0.8,
                  max: 1.4,
                  divisions: 6,
                  label: fontScaleLabel(temp),
                  onChanged: (v) => setSheetState(() => temp = v),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx, temp),
                    child: const Text('确定'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (result != null) await prefs.writeFontScale(result);
  }
}

/// 实时预览：跟随当前字号设置显示一段示例正文。
///
/// 单独放一个预览区，是因为字号只有一个百分比标签时，
/// 用户很难判断"大"到底有多大。
class _FontPreview extends StatelessWidget {
  const _FontPreview();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final prefs = context.read<PreferencesService>();

    return StreamBuilder<double>(
      stream: prefs.watchFontScale(),
      builder: (context, snap) {
        final scale = snap.data ?? 1.0;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '示例标题',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontSize: 22 * scale,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    '这段文字按当前字号渲染。写笔记时看到的正文大小就是它——'
                    '嫌小就往右拖，嫌大就往左拖。',
                    style: TextStyle(fontSize: 16 * scale, height: 1.7),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
