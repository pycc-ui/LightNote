import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/database_location.dart';
import '../../../core/secure/secure_store.dart';
import '../../../core/theme/dimens.dart';
import '../../../core/backup/backup_service.dart';
import '../../../core/prefs/preferences_service.dart';
import 'pages/about_settings_page.dart';
import 'pages/ai_settings_page.dart';
import 'pages/appearance_settings_page.dart';
import 'pages/editor_settings_page.dart';
import 'pages/storage_settings_page.dart';
import 'pages/usage_settings_page.dart';

/// 设置首页。
///
/// **只做导航，不在这里改任何东西。**
///
/// 改之前这里是一个 1400 多行的长列表，主题下拉、字号滑块、
/// API Key 输入框、备份按钮、新卡上限滑块全挤在同一页滚动到底——
/// 两个问题：
///   · 想改个主题要滚过一堆不相关的东西；
///   · 破坏性操作（换工作目录、导入备份包）和日常开关混在一起，容易误触。
///
/// 现在每一项都是「图标 + 名称 + **当前值** + 箭头」，点进去才改。
/// 当前值直接显示在列表上，所以大多数时候不用点进去就能确认状态。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String _dbDirLabel = '读取中…';
  String _backupLabel = '';
  bool _dbDirWarn = false;

  @override
  void initState() {
    super.initState();
    _loadSummaries();
  }

  /// 汇总各子页的当前状态，显示在首页列表项右侧。
  ///
  /// 每段单独容错：这里只是展示，任何一项算不出来都不该让首页打不开。
  Future<void> _loadSummaries() async {
    String dir = '读取中…';
    var warn = false;
    try {
      final info = await DatabaseLocation.describeSafe();
      final db = context.read<AppDatabase>();
      final path = db.databasePath;
      // 只显示最后一段（目录名），完整路径在子页里看
      dir = path == '(尚未打开)'
          ? path
          : path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).last;
      if (info.isDegradedToProgramDir) {
        dir = '临时位置（有风险）';
        warn = true;
      } else if (info.isPrivate) {
        dir = 'App 私有目录';
      } else if (info.isEnvOverridden) {
        dir = '环境变量指定';
      } else {
        dir = '自定义目录';
      }
    } catch (e) {
      debugPrint('读取存储位置失败：$e');
      dir = '(读取失败)';
    }

    var backup = '';
    try {
      final list = await context.read<BackupService>().listAutoBackups();
      if (list.isNotEmpty) backup = '私有目录留有 ${list.length} 份';
    } catch (_) {
      // 备份数拿不到就不显示
    }

    if (!mounted) return;
    setState(() {
      _dbDirLabel = dir;
      _dbDirWarn = warn;
      _backupLabel = backup;
    });
  }

  @override
  Widget build(BuildContext context) {
    final prefs = context.read<PreferencesService>();

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: [
          _groupHeader('个性化'),
          _group([
            // 外观 —— 当前值直接从偏好流里取
            StreamBuilder<String>(
              stream: prefs.watchThemeMode(),
              builder: (context, snap) {
                final mode = snap.data ?? 'system';
                return _navTile(
                  context,
                  icon: Icons.palette_outlined,
                  title: '外观',
                  subtitle: AppearanceSettingsPage.themeModeLabel(mode),
                  page: const AppearanceSettingsPage(),
                );
              },
            ),
            _navTile(
              context,
              icon: Icons.edit_note_outlined,
              title: '编辑器',
              subtitle: '手动保存',
              page: const EditorSettingsPage(),
            ),
          ]),

          _groupHeader('AI'),
          _group([
            const _AiTile(),
          ]),

          _groupHeader('数据'),
          _group([
            _navTile(
              context,
              icon: Icons.library_books_outlined,
              title: '存储与备份',
              subtitle: _dbDirWarn
                  ? '⚠️ $_dbDirLabel'
                  : (_backupLabel.isEmpty
                      ? _dbDirLabel
                      : '$_dbDirLabel · $_backupLabel'),
              subtitleColor: _dbDirWarn
                  ? Theme.of(context).colorScheme.error
                  : null,
              page: const StorageSettingsPage(),
              // 从子页回来时刷新摘要（可能换了目录或导出了备份）
              onReturn: _loadSummaries,
            ),
          ]),

          _groupHeader('其他'),
          _group([
            _navTile(
              context,
              icon: Icons.bar_chart_outlined,
              title: '用量与成本',
              subtitle: '查看累计 AI 花费',
              page: const UsageSettingsPage(),
            ),
            _navTile(
              context,
              icon: Icons.info_outline,
              title: '关于',
              subtitle: '版本、技术栈、隐私说明',
              page: const AboutSettingsPage(),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _groupHeader(String text) {
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

  Widget _group(List<Widget> children) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _navTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget page,
    Color? subtitleColor,
    Future<void> Function()? onReturn,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(
        subtitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: subtitleColor == null ? null : TextStyle(color: subtitleColor),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => page),
        );
        // 回到首页时刷新摘要：用户可能在里面改了设置
        if (onReturn != null) await onReturn();
      },
    );
  }
}

/// AI 摘要项：显示能否用、当前模型
class _AiTile extends StatefulWidget {
  const _AiTile();

  @override
  State<_AiTile> createState() => _AiTileState();
}

class _AiTileState extends State<_AiTile> {
  bool _hasKey = false;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final key = await SecureStore.readApiKey();
    if (!mounted) return;
    setState(() {
      _hasKey = key != null;
      _ready = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(
        _ready && !_hasKey ? Icons.error_outline : Icons.auto_awesome_outlined,
        color: _ready && !_hasKey ? theme.colorScheme.error : null,
      ),
      title: const Text('AI'),
      subtitle: Text(
        !_ready
            ? '读取中…'
            : (_hasKey ? '已配置 Key' : '尚未配置 API Key'),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const AiSettingsPage()),
        );
        if (mounted) await _load();
      },
    );
  }
}

