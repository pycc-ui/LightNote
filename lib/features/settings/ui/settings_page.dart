import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

// 隐藏 Drift 的 Card 类（由 cards 表生成），避免与 Flutter 的 Card 组件冲突。
import '../../../core/app_info.dart';
import '../../../core/db/app_database.dart' hide Card;
import '../../../core/db/database_location.dart';
import '../../../core/secure/secure_store.dart';
import '../../../core/theme/dimens.dart';
import '../../../core/ui/log_bar.dart';
import '../../../services/backup/app_restart.dart';
import '../../../services/backup/backup_models.dart';
import '../../../services/backup/backup_service.dart';
import '../../../services/backup/file_dialogs.dart';
import '../../../services/backup/pending_import.dart';
import '../../../services/markdown_export_service.dart';
import '../../../services/preferences_service.dart';
import '../../ai/data/deepseek_config.dart';
import '../../ai/domain/ai_chat_repository.dart';
import '../../ai/domain/ai_repository.dart';

/// 设置页（设计稿 §5.7 / 线框图 4.7）
///
/// 分区：外观 / 编辑器 / 存储与备份 / AI / 记忆卡片 / 用量 / 关于。
/// 设计稿只列了前几节，AI 与备份两节是本项目补的：
///   · AI：接入真实 DeepSeek 后，API Key 与费用必须可管理；
///   · 备份：数据库默认在 App 私有目录，用户看不到也摸不到，
///     不给一个"整库导出/导入"的出口就是数据孤岛。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _keyController = TextEditingController();

  bool _loaded = false;
  bool _obscure = true;
  bool _hasKey = false;
  bool _thinking = false;
  bool _privacyAccepted = false;
  String _model = DeepSeekConfig.modelFlash;
  int _dailyNewCards = 15;

  String? _testResult;
  bool _testing = false;
  bool _savingKey = false;

  // ---- 存储与备份 ----
  bool _busy = false;
  String _busyLabel = '';
  DatabaseLocationInfo? _location;
  String _dbPath = '';
  int _autoBackupCount = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final key = await SecureStore.readApiKey();
    final model = await SecureStore.readModel();
    final thinking = await SecureStore.readThinkingEnabled();
    final daily = await SecureStore.readDailyNewCards();
    if (!mounted) return;
    final privacy = await context.read<AiChatRepository>().hasPrivacyConsent();
    if (!mounted) return;

    setState(() {
      _hasKey = key != null;
      // 已保存的 Key 不回填明文，只显示状态；用户想换就直接输入新的
      _model = model;
      _thinking = thinking;
      _dailyNewCards = daily;
      _privacyAccepted = privacy;
      _loaded = true;
    });

    await _refreshStorageInfo();
  }

  /// 读取数据库位置与自动留档数量。
  ///
  /// 数据库路径取的是 `AppDatabase.databasePath`（打开时记下的真实路径），
  /// 而不是在这里重新解析一次——两处各自解析可能给出不同答案，
  /// 那样设置页就会"说得和做得不一样"。
  ///
  /// 用 [DatabaseLocation.describeSafe]：它保证不抛异常。
  /// 设置页只是展示信息，绝不能因为解析位置失败就整页打崩。
  Future<void> _refreshStorageInfo() async {
    try {
      final info = await DatabaseLocation.describeSafe();
      final db = context.read<AppDatabase>();
      final backups = await context.read<BackupService>().listAutoBackups();
      // 诊断文本是按需展开的，这里先不算，点"查看详情"时再算
      if (!mounted) return;
      setState(() {
        _location = info;
        _dbPath = db.databasePath;
        _autoBackupCount = backups.length;
      });
    } catch (e) {
      if (!mounted) return;
      debugPrint('读取存储信息失败：$e');
    }
  }

  /// 弹出完整的位置解析过程，供排查"数据到底在哪"。
  Future<void> _showDiagnostics() async {
    final text = await DatabaseLocation.diagnose();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('数据库位置诊断'),
        content: SingleChildScrollView(
          child: SelectableText(
            text,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('复制用说明：选中文字即可复制'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  void _setBusy(String label) => setState(() {
        _busy = true;
        _busyLabel = label;
      });

  void _clearBusy() {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _busyLabel = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final prefs = context.read<PreferencesService>();

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: [
          // ---------------- 外观 ----------------
          const _SectionHeader('外观'),
          StreamBuilder<String>(
            stream: prefs.watchThemeMode(),
            builder: (context, snap) {
              final mode = snap.data ?? 'system';
              return ListTile(
                leading: const Icon(Icons.palette_outlined),
                title: const Text('主题'),
                subtitle: Text(switch (mode) {
                  'light' => '浅色',
                  'dark' => '深色',
                  _ => '跟随系统',
                }),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _pickTheme(prefs, mode),
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
                subtitle: Text(_fontScaleLabel(scale)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _pickFontScale(prefs, scale),
              );
            },
          ),

          // ---------------- 编辑器 ----------------
          const _SectionHeader('编辑器'),
          StreamBuilder<bool>(
            stream: prefs.watchAutoSave(),
            builder: (context, snap) {
              final enabled = snap.data ?? true;
              return SwitchListTile(
                secondary: const Icon(Icons.save_outlined),
                title: const Text('自动保存'),
                subtitle: Text(
                  enabled ? '停止输入 0.5 秒后自动保存' : '需要手动保存',
                ),
                value: enabled,
                onChanged: (v) => prefs.writeAutoSave(v),
              );
            },
          ),

          // ---------------- 存储与备份 ----------------
          const _SectionHeader('存储位置'),
          _storageLocationCard(context),

          const _SectionHeader('备份与恢复'),
          ListTile(
            leading: const Icon(Icons.archive_outlined),
            title: const Text('导出备份包（.zip）'),
            subtitle: const Text('把整库导出成一个压缩包，自己选存放位置'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : _exportBackup,
          ),
          ListTile(
            leading: const Icon(Icons.unarchive_outlined),
            title: const Text('从备份包导入'),
            subtitle: const Text('选一个 .zip，校验后恢复（会先重启 App）'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : _importBackup,
          ),
          ListTile(
            leading: const Icon(Icons.ios_share),
            title: const Text('导出 Markdown'),
            subtitle: const Text('按目录整理成一个 .md 文件，便于贴到别处'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : _exportAll,
          ),
          if (_location != null && !_location!.isPrivate)
            ListTile(
              leading: const Icon(Icons.undo),
              title: const Text('恢复默认存储位置'),
              subtitle: const Text('把笔记搬回 App 私有目录，并重启'),
              onTap: _busy ? null : () => _changeWorkingDir(null),
            ),

          const _SectionHeader('维护'),
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('清空 AI 历史'),
            subtitle: const Text('删除摘要记录与调用审计，笔记本身不受影响'),
            onTap: _clearAiHistory,
          ),

          if (_busy) ...[
            const SizedBox(height: AppSpacing.md),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: AppSpacing.sm + 4),
                  Expanded(
                    child: Text(
                      _busyLabel,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ],

          // ---------------- AI ----------------
          const _SectionHeader('AI'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _hasKey ? Icons.check_circle : Icons.error_outline,
                        size: 18,
                        color: _hasKey
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        _hasKey ? 'API Key 已配置' : '尚未配置 API Key',
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Key 只保存在本机系统钥匙串（Android Keystore），'
                    '不会写入代码、日志或联网上传。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          height: 1.5,
                        ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TextField(
                    controller: _keyController,
                    obscureText: _obscure,
                    decoration: InputDecoration(
                      labelText: _hasKey ? '输入新的 Key 以替换' : 'sk-...',
                      prefixIcon: const Icon(Icons.key_outlined),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscure ? Icons.visibility_off : Icons.visibility,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm + 4),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: _savingKey ? null : _saveKey,
                          child: Text(_savingKey ? '保存中…' : '保存 Key'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _testing ? null : _test,
                          child: Text(_testing ? '测试中…' : '测试连接'),
                        ),
                      ),
                    ],
                  ),
                  if (_testResult != null) ...[
                    const SizedBox(height: AppSpacing.sm + 4),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest
                            .withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _testResult!,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(height: 1.5),
                      ),
                    ),
                  ],
                  if (_hasKey)
                    TextButton.icon(
                      onPressed: _clearKey,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('删除已保存的 Key'),
                      style: TextButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.memory),
            title: const Text('模型'),
            subtitle: Text(_model),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickModel(),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.psychology_outlined),
            title: const Text('深度整理时启用思考模式'),
            subtitle: const Text(
              '开启后「AI 整理要点」会先推理再给结论，质量更好但更慢更贵。'
              'DeepSeek 侧默认是开启的，这里默认关闭以免浪费。',
            ),
            value: _thinking,
            onChanged: (v) async {
              setState(() => _thinking = v);
              await SecureStore.writeThinkingEnabled(v);
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.privacy_tip_outlined),
            title: const Text('AI 数据使用授权'),
            subtitle: Text(
              _privacyAccepted
                  ? '已授权。发送时只会带上你显式勾选的笔记。'
                  : '未授权，AI 页无法发送指令。',
            ),
            value: _privacyAccepted,
            onChanged: (v) async {
              final repo = context.read<AiChatRepository>();
              if (v) {
                await repo.acceptPrivacy();
              } else {
                await repo.revokePrivacy();
              }
              if (mounted) setState(() => _privacyAccepted = v);
            },
          ),

          // ---------------- 复习 ----------------
          const _SectionHeader('记忆卡片'),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(child: Text('每日新卡上限')),
                      Text(
                        '$_dailyNewCards 张',
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  Slider(
                    value: _dailyNewCards.toDouble(),
                    min: 5,
                    max: 50,
                    divisions: 9,
                    label: '$_dailyNewCards',
                    onChanged: (v) =>
                        setState(() => _dailyNewCards = v.round()),
                    onChangeEnd: (v) =>
                        SecureStore.writeDailyNewCards(v.round()),
                  ),
                  Text(
                    '新卡会和到期旧卡混在一起。上限设太高容易在积压时劝退，'
                    '建议 10–20 张。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          height: 1.5,
                        ),
                  ),
                ],
              ),
            ),
          ),

          // ---------------- 用量 ----------------
          const _SectionHeader('用量与成本'),
          const _CostCard(),

          // ---------------- 关于 ----------------
          const _SectionHeader('关于'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('版本'),
            subtitle: Text('$kAppDisplayName v$kAppVersion'),
          ),
          const ListTile(
            leading: Icon(Icons.build_outlined),
            title: Text('技术栈'),
            subtitle: Text('Flutter · Dart · SQLite(Drift) · DeepSeek'),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Text(
              '本 App 数据默认只存本机，不联网、不同步。\n'
              '只有在你主动使用 AI 功能并勾选笔记时，相关内容才会发送给 DeepSeek。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    height: 1.6,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  static String _fontScaleLabel(double scale) {
    if (scale < 0.9) return '小（${(scale * 100).round()}%）';
    if (scale < 1.05) return '中（100%）';
    if (scale < 1.2) return '大（${(scale * 100).round()}%）';
    return '特大（${(scale * 100).round()}%）';
  }

  // ==========================================================================
  // 存储位置
  // ==========================================================================

  Widget _storageLocationCard(BuildContext context) {
    final theme = Theme.of(context);
    final loc = _location;
    final isPrivate = loc?.isPrivate ?? true;
    final envOverridden = loc?.isEnvOverridden ?? false;
    final rootUnavailable = loc?.privateRootUnavailable ?? false;
    final degradedToProgramDir = loc?.isDegradedToProgramDir ?? false;

    final (IconData icon, String title) = switch (true) {
      _ when degradedToProgramDir =>
        (Icons.error_outline, '临时位置（有丢失风险）'),
      _ when envOverridden => (Icons.terminal, '环境变量指定（调试）'),
      _ when rootUnavailable => (Icons.warning_amber_outlined, '自定义位置（私有目录不可用）'),
      _ when isPrivate => (Icons.lock_outline, 'App 私有目录（默认）'),
      _ => (Icons.folder_open_outlined, '自定义工作目录'),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            SelectableText(
              _dbPath.isEmpty ? '(正在读取…)' : _dbPath,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                height: 1.5,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              switch (true) {
                _ when degradedToProgramDir =>
                  '所有常规位置都写不进去（AppData、文档目录、用户主目录），'
                      '所以数据落在了**程序所在目录**里。'
                      '这个位置在 build\\ 下面，一次 flutter clean 或手工删 build\\ '
                      '就会连数据一起删掉。请尽快用下面的「更换工作目录」挪到安全位置。',
                _ when envOverridden =>
                  '数据库位置由环境变量 $kDbDirEnvOverride 指定，'
                      '这是调试/CI 用的开关，正常使用时不会有这一行。',
                _ when rootUnavailable =>
                  'App 私有目录这次没能创建出来（多见于受限账户或安全软件拦截），'
                      '所以数据写到了上面这个位置。建议用「导出备份包」把它挪到安全的地方。',
                _ when !isPrivate =>
                  '笔记库放在你自己选的目录里，重装 App 或换设备都不会丢；'
                      '但那个目录下的 $kDatabaseFileName 文件不要手动改，也不要删。',
                _ =>
                  '笔记库是一个单独的 SQLite 文件，放在 App 私有目录里，'
                      '不会出现在相册或文件管理器里。'
                      '重新编译、删 build 目录、flutter clean 都不会影响它。'
                      '想拿到别处、或想在电脑上直接打开，用下面的「导出备份包」。',
              },
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.6,
              ),
            ),
            if (degradedToProgramDir) ...[
              const SizedBox(height: AppSpacing.sm),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '⚠️ 数据在 build\\ 目录里，有丢失风险',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '原因：${loc?.degradedNote ?? '常规位置均不可写'}\n\n'
                      '建议：点下面的「更换工作目录」选一个安全目录，'
                      'App 会把数据复制过去并重启。',
                      style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
                    ),
                  ],
                ),
              ),
            ],
            if (loc?.isFallback == true && !degradedToProgramDir) ...[
              const SizedBox(height: AppSpacing.sm),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '注意：你指定的工作目录这次没能使用，数据暂时写在别的位置。\n'
                  '原因：${loc?.fallbackNote ?? '未知'}',
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
                ),
              ),
            ],
            if (_autoBackupCount > 0) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                '私有目录里已留有 $_autoBackupCount 份导出备份（backups/）。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.sm + 4),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: (_busy || rootUnavailable)
                        ? null
                        : _pickWorkingDirectory,
                    icon: const Icon(Icons.drive_file_move_outline, size: 18),
                    label: Text(isPrivate ? '更换工作目录' : '更换目录'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _showDiagnostics,
                  icon: const Icon(Icons.troubleshoot, size: 18),
                  label: const Text('诊断'),
                ),
              ],
            ),
            if (rootUnavailable)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Text(
                  '私有目录不可用，暂时无法切换工作目录；'
                  '请先用导出/导入备份包。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ),
            if (!FileDialogs.directoryPickerIsReliable)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Text(
                  '提示：当前平台上系统的目录选择器给不出可写路径，'
                  '「更换工作目录」可能不可用。请改用导出/导入备份包。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickTheme(PreferencesService prefs, String current) async {
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

  Future<void> _pickFontScale(PreferencesService prefs, double current) async {
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
                Text('编辑器字体大小', style: Theme.of(ctx).textTheme.titleMedium),
                const SizedBox(height: AppSpacing.md),
                Text(
                  '示例文字：轻笔记',
                  style: TextStyle(fontSize: 16 * temp),
                ),
                Slider(
                  value: temp,
                  min: 0.8,
                  max: 1.4,
                  divisions: 6,
                  label: _fontScaleLabel(temp),
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

  Future<void> _pickModel() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(_model == DeepSeekConfig.modelFlash
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked),
              title: const Text(DeepSeekConfig.modelFlash),
              subtitle: const Text('速度快、价格低，日常整理与问答足够'),
              onTap: () => Navigator.pop(ctx, DeepSeekConfig.modelFlash),
            ),
            ListTile(
              leading: Icon(_model == DeepSeekConfig.modelPro
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked),
              title: const Text(DeepSeekConfig.modelPro),
              subtitle: const Text('更强推理，适合复杂笔记的结构化整理'),
              onTap: () => Navigator.pop(ctx, DeepSeekConfig.modelPro),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(
                  AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.md),
              child: Text(
                'DeepSeek 思考模式默认开启且强度为 high。'
                '本 App 在轻量任务上会自动关闭它，以免产生不必要的耗时与费用。',
                style: TextStyle(fontSize: 12, height: 1.5),
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    setState(() => _model = picked);
    await SecureStore.writeModel(picked);
  }

  Future<void> _saveKey() async {
    final key = _keyController.text.trim();
    if (key.isEmpty) {
      LogBar.info(context, '请输入 API Key');
      return;
    }
    if (!key.startsWith('sk-')) {
      LogBar.info(context, '看起来不像 DeepSeek 的 Key（通常以 sk- 开头），仍会保存。');
    }
    setState(() => _savingKey = true);
    await context.read<AiRepository>().saveApiKey(key);
    if (!mounted) return;
    setState(() {
      _savingKey = false;
      _hasKey = true;
      _keyController.clear();
    });
    LogBar.info(context, '已保存');
  }

  Future<void> _clearKey() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除 API Key'),
        content: const Text('删除后 AI 功能将不可用，已生成的摘要与卡片不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    await context.read<AiRepository>().clearApiKey();
    if (!mounted) return;
    setState(() {
      _hasKey = false;
      _testResult = null;
    });
    LogBar.info(context, '已删除');
  }

  Future<void> _test() async {
    final pending = _keyController.text.trim();
    setState(() {
      _testing = true;
      _testResult = null;
    });

    final repo = context.read<AiRepository>();
    try {
      // 输入框里有新 Key 时先用它测试，不落库
      if (pending.isNotEmpty) repo.client.setApiKey(pending);
      final result = await repo.testConnection(model: _model);
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testResult = '✅ 连接成功\n模型：$_model\n返回：$result';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testResult = '❌ 连接失败：$e';
      });
      // 测试用的临时 Key 不保留，恢复已保存的那个
      if (pending.isNotEmpty) await repo.init();
    }
  }

  Future<void> _clearAiHistory() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空 AI 历史'),
        content: const Text(
          '将删除全部 AI 摘要记录与调用审计数据。\n'
          '笔记正文、标签、记忆卡片都不受影响，'
          '但笔记阅读页顶部的 AI 摘要会消失。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认清空'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<AppDatabase>().clearAiHistory();
    if (!mounted) return;
    LogBar.info(context, '已清空');
  }

  // ==========================================================================
  // 导出备份包
  // ==========================================================================

  Future<void> _exportBackup() async {
    final dialogs = context.read<FileDialogs>();
    final backup = context.read<BackupService>();

    // 先让用户选位置。取消的话不当作失败——很多人只是想看看弹窗长什么样，
    // 这时直接退回到"私有目录也留一份"，比弹一个失败提示友好。
    String? target;
    try {
      target = await dialogs.pickExportTarget(
        suggestedName: BackupService.defaultArchiveName(),
      );
    } catch (e) {
      LogBar.error(context, '打开保存对话框失败：$e');
      return;
    }

    if (!mounted) return;

    // 选完位置才置忙：对话框期间不该显示"正在导出"
    _setBusy(target == null ? '保存到私有目录…' : '正在导出…');
    try {
      if (target == null) {
        // 未选位置：生成到私有目录的 backups/ 里
        final fallbackDir = await _privateBackupDir();
        target = p.join(fallbackDir, BackupService.defaultArchiveName());
      }

      final outcome = await backup.exportTo(target);
      await _refreshStorageInfo();
      if (!mounted) return;
      _clearBusy();
      await _showExportResult(outcome);
    } catch (e) {
      if (!mounted) return;
      _clearBusy();
      LogBar.error(context, '导出失败：$e');
    }
  }

  Future<String> _privateBackupDir() async {
    final root = await DatabaseLocation.privateRoot();
    final dir = Directory(p.join(root.path, BackupService.autoBackupFolder));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }

  Future<void> _showExportResult(ExportOutcome outcome) async {
    final extra = outcome.autoCopyError != null
        ? '\n\n另外在私有目录留档失败：${outcome.autoCopyError}'
        : (outcome.autoCopyDir != null
            ? '\n\n私有目录同时留了一份：\n${outcome.autoCopyDir}'
            : '');
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('备份已导出'),
        content: SingleChildScrollView(
          child: Text(
            '${outcome.primaryPath}\n\n'
            '大小：${outcome.sizeLabel}\n'
            '内容：${outcome.stats.summary}$extra\n\n'
            '这个 .zip 里是一个标准的 SQLite 数据库文件，'
            '换电脑、换手机、重装 App 都可以用它恢复。\n'
            '注意：备份里**不包含** DeepSeek API Key。',
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  // ==========================================================================
  // 导入备份包
  // ==========================================================================

  Future<void> _importBackup() async {
    final dialogs = context.read<FileDialogs>();
    final backup = context.read<BackupService>();

    String? archive;
    try {
      archive = await dialogs.pickArchiveToImport();
    } catch (e) {
      LogBar.error(context, '打开文件选择器失败：$e');
      return;
    }
    if (archive == null || !mounted) return;

    _setBusy('正在校验备份包…');
    final ImportPreview preview;
    try {
      preview = await backup.inspect(archive);
    } on BackupException catch (e) {
      if (!mounted) return;
      _clearBusy();
      await _showImportRejected(e.message);
      return;
    } catch (e) {
      if (!mounted) return;
      _clearBusy();
      LogBar.error(context, '备份包无法使用：$e');
      return;
    }
    if (!mounted) return;
    _clearBusy();

    final choice = await _confirmImport(preview);
    if (choice == null || !mounted) return;

    _setBusy('正在安排导入…');
    try {
      final pending = PendingImport.create(
        archivePath: preview.archivePath,
        strategy: choice.strategy,
        stats: preview.manifest.stats,
        importedAt: DateTime.now().toUtc(),
      );
      await pending.write();
    } catch (e) {
      if (!mounted) return;
      _clearBusy();
      LogBar.error(context, '写入待导入标记失败：$e');
      return;
    }
    if (!mounted) return;
    _clearBusy();

    await _restartWithExplanation(
      title: '导入将在重启后完成',
      body: '当前数据库已经被打开，无法在原地替换。'
          '请让 App 重启一次，启动瞬间会自动完成换库。',
    );
  }

  Future<void> _showImportRejected(String reason) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('这个备份包不能用'),
        content: SingleChildScrollView(child: Text(reason)),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<({ImportStrategy strategy})?> _confirmImport(ImportPreview preview) {
    var strategy = ImportStrategy.replace;

    return showDialog<({ImportStrategy strategy})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('确认导入'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('备份来自：${preview.manifest.createdAtLabel}'),
                const SizedBox(height: 6),
                Text('来源平台：${preview.manifest.sourcePlatform}'),
                const SizedBox(height: 6),
                Text('内容：${preview.manifest.stats.summary}'),
                const SizedBox(height: AppSpacing.md),
                Text(
                  '当前 App 里的数据：\n'
                  '· 覆盖：导入前的库会先备份到私有目录 backups/，可回退\n'
                  '· 保留：导入前的库改名成 before-import-….sqlite 留在同目录',
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(height: 1.6),
                ),
                const SizedBox(height: AppSpacing.sm),
                // 用 RadioGroup 而不是给每个 RadioListTile 传 groupValue：
                // Flutter 3.32 起 groupValue/onChanged 已废弃，
                // 旧写法在 analyze 里会刷一屏 deprecation。
                RadioGroup<ImportStrategy>(
                  groupValue: strategy,
                  onChanged: (v) => setDialogState(() => strategy = v!),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      RadioListTile<ImportStrategy>(
                        value: ImportStrategy.replace,
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text('覆盖当前数据'),
                      ),
                      RadioListTile<ImportStrategy>(
                        value: ImportStrategy.keepBoth,
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text('保留为另一个文件'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, (strategy: strategy)),
              child: const Text('导入并重启'),
            ),
          ],
        ),
      ),
    );
  }

  // ==========================================================================
  // 工作目录
  // ==========================================================================

  Future<void> _pickWorkingDirectory() async {
    if (!FileDialogs.directoryPickerIsReliable) {
      LogBar.info(context, '当前平台的目录选择器给不出可写路径，请改用导出/导入备份包。');
      return;
    }

    final dialogs = context.read<FileDialogs>();
    final picked = await dialogs.pickWorkingDirectory(
      initialDirectory: _location?.activeDir,
    );
    if (picked == null || !mounted) return;
    await _changeWorkingDir(picked);
  }

  /// 切换工作目录。
  ///
  /// [target] 传 null 表示恢复默认（私有目录）。
  ///
  /// 做法上有两个必须这样处理的点：
  ///   1. 先把当前数据以**一致性快照**搬到新目录，否则换过去会得到一个空 App；
  ///   2. 真正生效要等下次启动（配置文件在启动时才读），所以统一走重启。
  Future<void> _changeWorkingDir(String? target) async {
    final backup = context.read<BackupService>();

    // 私有目录不可用时 privateRoot() 会抛异常。
    // 这里只是"恢复默认"要用到它，取不到就不该让整个操作崩掉。
    Directory? privateRoot;
    try {
      privateRoot = await DatabaseLocation.privateRoot();
    } catch (_) {
      privateRoot = null;
    }
    if (target == null && privateRoot == null) {
      LogBar.info(context, 'App 私有目录当前不可用，无法恢复默认位置。');
      return;
    }

    final targetDir =
        target == null ? privateRoot! : Directory(p.normalize(target));
    final current = _location?.activeDir;

    if (current != null && p.equals(p.normalize(current), targetDir.path)) {
      LogBar.info(context, '已经是当前目录了');
      return;
    }

    // 目标目录里已经有数据库文件：**绝不覆盖**。
    // 这多半是用户之前用过的目录，里面有他的旧笔记。
    final existingDb = File(DatabaseLocation.dbPathIn(targetDir));
    if (existingDb.existsSync()) {
      final useExisting = await _askAboutExistingDb(existingDb.path);
      if (useExisting == null || !mounted) return;
      if (useExisting) {
        // 采用已有库：直接把配置指过去，不搬数据
        _setBusy('正在切换…');
        try {
          await DatabaseLocation.writeConfiguredDir(targetDir.path);
        } catch (e) {
          if (!mounted) return;
          _clearBusy();
          LogBar.error(context, '写入配置失败：$e');
          return;
        }
        if (!mounted) return;
        _clearBusy();
        await _restartWithExplanation(
          title: '工作目录已切换',
          body: '重启后会使用 ${targetDir.path} 里已有的数据库。',
        );
        return;
      }
    }

    // 正式流程：快照 → 落地 → 写配置 → 重启
    _setBusy('正在把数据搬到新目录…');
    try {
      final err = DatabaseLocation.probeWritable(targetDir);
      if (err != null) {
        throw BackupException('这个目录不可写：$err');
      }
      final snapshot = File(DatabaseLocation.dbPathIn(targetDir));
      await backup.snapshotToNewFile(snapshot.path);
      await DatabaseLocation.writeConfiguredDir(
        (privateRoot != null && p.equals(targetDir.path, privateRoot.path))
            ? null
            : targetDir.path,
      );
    } catch (e) {
      if (!mounted) return;
      _clearBusy();
      LogBar.error(context, '切换失败：$e');
      return;
    }
    if (!mounted) return;
    _clearBusy();

    await _restartWithExplanation(
      title: '工作目录已切换',
      body: '笔记已经复制到：\n${targetDir.path}\n\n'
          '重启后 App 会改用这个位置。旧位置的文件仍然保留，确认无误后可自行删除。',
    );
  }

  /// 目标目录已有数据库时让用户决定。返回 true=用那个库，false=另择，null=取消。
  Future<bool?> _askAboutExistingDb(String dbPath) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('这个目录里已经有笔记库'),
        content: SingleChildScrollView(
          child: Text(
            '$dbPath\n\n'
            '如果这是你以前用过的目录，选「使用它」可以直接接着用里面的笔记；\n'
            '注意：这种情况下当前 App 里的数据不会被带过去（但会留在原位置）。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('换个目录'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('使用它'),
          ),
        ],
      ),
    );
  }

  /// 提示重启，并真的尝试重启。
  Future<void> _restartWithExplanation({
    required String title,
    required String body,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(body)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('稍后手动重启'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('立即重启'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      LogBar.info(context, '已记录。请手动关闭并重新打开 App 完成切换。');
      return;
    }
    final ok = await AppRestart.restart();
    if (!ok && mounted) {
      LogBar.info(context, '当前平台不支持自动重启，请手动关闭再打开 App。');
    }
  }

  // ==========================================================================
  // 导出 Markdown（保留原有能力，与整库备份互补）
  // ==========================================================================

  Future<void> _exportAll() async {
    final prefs = context.read<PreferencesService>();
    _setBusy('正在导出 Markdown…');
    try {
      final path = await context.read<MarkdownExportService>().exportAll();
      await prefs.markExportRecallSeen();
      if (!mounted) return;
      _clearBusy();
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Markdown 已导出'),
          content: SingleChildScrollView(
            child: Text(
              '已导出到：\n\n$path\n\n'
              '这是 App 内部目录，只适合临时取用。'
              '要长期保存或搬到别的设备，请用「导出备份包（.zip）」，'
              '它可以自己选位置，而且能完整恢复所有数据。',
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _clearBusy();
      LogBar.error(context, '导出失败：$e');
    }
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.xs,
      ),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
          color: theme.colorScheme.primary,
        ),
      ),
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
                  '按 DeepSeek 官方公布的价格估算（区分高峰/空闲时段，'
                  '空闲时段价格是高峰的一半）。实际扣费以官方账单为准。',
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
