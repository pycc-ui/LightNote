import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../../core/db/app_database.dart';
import '../../../../core/db/database_location.dart';
import '../../../../core/theme/dimens.dart';
import '../../../../core/widgets/log_bar.dart';
import '../../../../core/backup/app_restart.dart';
import '../../../../core/backup/backup_models.dart';
import '../../../../core/backup/backup_service.dart';
import '../../../../core/backup/file_dialogs.dart';
import '../../../../core/backup/pending_import.dart';
import '../widgets/settings_scaffold.dart';

/// 存储位置与备份恢复。
///
/// 这一页集中了所有"会碰数据文件"的操作：
/// 看数据库在哪、换工作目录、导出/导入备份包、清空 AI 历史。
/// 独立成页的理由是这些操作都不可逆（或需要重启），
/// 摊在一个长列表里容易误触。
class StorageSettingsPage extends StatefulWidget {
  const StorageSettingsPage({super.key});

  @override
  State<StorageSettingsPage> createState() => _StorageSettingsPageState();
}

class _StorageSettingsPageState extends State<StorageSettingsPage> {
  bool _busy = false;
  String _busyLabel = '';
  DatabaseLocationInfo? _location;
  String _dbPath = '';
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final info = await DatabaseLocation.describeSafe();
      final db = context.read<AppDatabase>();
      if (!mounted) return;
      setState(() {
        _location = info;
        _dbPath = db.databasePath;
        _loaded = true;
      });
    } catch (e) {
      if (!mounted) return;
      debugPrint('读取存储信息失败：$e');
      setState(() => _loaded = true);
    }
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

  void _toast(String message) {
    if (!mounted) return;
    // 走 LogBar 而不是直接 showSnackBar：LogBar 里显式设了 persist: false，
    // 避免以后给提示加「撤销」按钮时又碰上"带 action 的 SnackBar 永不消失"那个坑。
    LogBar.info(context, message);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final loc = _location;
    final isPrivate = loc?.isPrivate ?? true;
    final rootUnavailable = loc?.privateRootUnavailable ?? false;

    return SettingsSubPage(
      title: '存储与备份',
      children: [
        if (_busy) _busyBanner(),
        const SettingsGroupHeader('数据放在哪'),
        _locationCard(context),
        const SettingsGroupHeader('备份与恢复'),
        SettingsGroup(
          children: [
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
          ],
        ),
        const SettingsNote(
          '备份包里**不含 API Key**（它在系统钥匙串里），新设备上需要重新填一次。',
        ),
        const SettingsGroupHeader('维护'),
        SettingsGroup(
          children: [
            ListTile(
              leading: const Icon(Icons.cleaning_services_outlined),
              title: const Text('清空 AI 历史'),
              subtitle: const Text('删除摘要记录与调用审计，笔记本身不受影响'),
              onTap: _busy ? null : _clearAiHistory,
            ),
            if (!isPrivate)
              ListTile(
                leading: const Icon(Icons.undo),
                title: const Text('恢复默认存储位置'),
                subtitle: const Text('把笔记搬回 App 私有目录，并重启'),
                onTap: _busy ? null : () => _changeWorkingDir(null),
              ),
          ],
        ),
        if (rootUnavailable)
          const SettingsAlertNote(
            title: '私有目录不可用',
            body: '暂时无法切换工作目录，请先用导出/导入备份包。',
          ),
      ],
    );
  }

  Widget _busyBanner() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        0,
      ),
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
    );
  }

  /// 存储位置卡片：显示真实路径 + 状态 + 换目录/诊断入口
  Widget _locationCard(BuildContext context) {
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
      _ when rootUnavailable =>
        (Icons.warning_amber_outlined, '自定义位置（私有目录不可用）'),
      _ when isPrivate => (Icons.lock_outline, 'App 私有目录（默认）'),
      _ => (Icons.folder_open_outlined, '自定义工作目录'),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: Card(
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
                        '所以数据落在了程序所在目录里。'
                        '请尽快用下面的「更换工作目录」挪到安全位置。',
                  _ when envOverridden =>
                    '数据库位置由环境变量 $kDbDirEnvOverride 指定，'
                        '这是调试/CI 用的开关，正常使用时不会有这一项。',
                  _ when rootUnavailable =>
                    'App 私有目录这次没能创建出来（多见于受限账户或安全软件拦截），'
                        '所以数据写到了上面这个位置。建议用「导出备份包」把它挪到安全的地方。',
                  _ when !isPrivate =>
                    '笔记库放在你自己选的目录里，重装 App 或换设备都不会丢；'
                        '但那个目录下的 $kDatabaseFileName 文件不要手动改，也不要删。',
                  _ =>
                    '笔记库是一个单独的 SQLite 文件，放在 App 私有目录里，'
                        '不会出现在相册或文件管理器里。'
                        '重新编译、删 build 目录、flutter clean 都不会影响它。',
                },
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.6,
                ),
              ),
              if (degradedToProgramDir) ...[
                const SizedBox(height: AppSpacing.sm),
                SettingsAlertNote(
                  title: '⚠️ 数据在 build\\ 目录里，有丢失风险',
                  body: '原因：${loc?.degradedNote ?? '常规位置均不可写'}\n\n'
                      '建议：点下面的「更换工作目录」选一个安全目录，'
                      'App 会把数据复制过去并重启。',
                  severe: true,
                ),
              ],
              if (loc?.isFallback == true && !degradedToProgramDir) ...[
                const SizedBox(height: AppSpacing.sm),
                SettingsAlertNote(
                  title: '你指定的工作目录这次没能使用',
                  body: '数据暂时写在别的位置。\n'
                      '原因：${loc?.fallbackNote ?? '未知'}',
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
                      icon:
                          const Icon(Icons.drive_file_move_outline, size: 18),
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
      ),
    );
  }

  // ==========================================================================
  // 诊断
  // ==========================================================================

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
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              height: 1.5,
            ),
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
  // 导出备份包
  // ==========================================================================

  Future<void> _exportBackup() async {
    final dialogs = context.read<FileDialogs>();
    final backup = context.read<BackupService>();

    ExportTarget? target;
    try {
      target = await dialogs.pickExportTarget(
        suggestedName: BackupService.defaultArchiveName(),
      );
    } catch (e) {
      _toast('打开保存对话框失败：$e');
      return;
    }
    if (!mounted) return;

    // Android 上的目标是缓存目录里的文件（用户看不到），写完要拉分享面板；
    // 桌面平台是用户自己挑的位置，直接写就行。原因见 FileDialogs.pickExportTarget。
    final viaShareSheet = target?.viaShareSheet ?? false;

    // 用户在保存对话框里取消了 —— 就到此为止。
    // 不要"兜底写进私有目录"：那等于用户没要也硬给他留一份。
    final targetPath = target?.path;
    if (targetPath == null) return;

    _setBusy(viaShareSheet ? '正在生成备份包…' : '正在导出…');
    try {
      final outcome = await backup.exportTo(targetPath);

      if (viaShareSheet) {
        // 拉不起分享面板（例如系统里根本没有能接收的应用）**不代表备份失败**：
        // 包已经生成，只是没能交给用户，所以这里只提示、不中断后续收尾。
        try {
          await dialogs.shareArchive(
            path: outcome.primaryPath,
            title: '选择备份包的去处',
          );
        } catch (e) {
          if (!mounted) return;
          _toast('备份包已生成，但没能打开分享面板：$e');
        }
      }

      await _refresh();
      if (!mounted) return;
      _clearBusy();
      await _showExportResult(outcome, viaShareSheet: viaShareSheet);
    } catch (e) {
      if (!mounted) return;
      _clearBusy();
      _toast(viaShareSheet ? '生成备份包失败：$e' : '导出失败：$e');
    }
  }


  Future<void> _showExportResult(
    ExportOutcome outcome, {
    bool viaShareSheet = false,
  }) async {
    // Android 上的落点是 App 缓存目录，那个路径用户既看不到也用不上
    // （文件管理器进不去），所以那里**不报路径**，只说"去分享面板里选去处"。
    // 桌面平台照旧把完整路径给出来，用户能直接去那儿找文件。
    final where = viaShareSheet
        ? '已生成备份包。请在分享面板中选「保存到文件 / 发微信 / 发网盘」'
            '决定它的去处。'
        : outcome.primaryPath;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(viaShareSheet ? '备份包已生成' : '备份已导出'),
        content: SingleChildScrollView(
          child: Text(
            '$where\n\n'
            '大小：${outcome.sizeLabel}\n'
            '内容：${outcome.stats.summary}\n\n'
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
      _toast('打开文件选择器失败：$e');
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
      _toast('备份包无法使用：$e');
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
      _toast('写入待导入标记失败：$e');
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
                  style:
                      Theme.of(ctx).textTheme.bodySmall?.copyWith(height: 1.6),
                ),
                const SizedBox(height: AppSpacing.sm),
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
      _toast('当前平台的目录选择器给不出可写路径，请改用导出/导入备份包。');
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
  /// 两个必须这样处理的点：
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
      _toast('App 私有目录当前不可用，无法恢复默认位置。');
      return;
    }

    final targetDir =
        target == null ? privateRoot! : Directory(p.normalize(target));
    final current = _location?.activeDir;

    if (current != null && p.equals(p.normalize(current), targetDir.path)) {
      _toast('已经是当前目录了');
      return;
    }

    // 目标目录里已经有数据库文件：**绝不覆盖**。
    // 这多半是用户之前用过的目录，里面有他的旧笔记。
    final existingDb = File(DatabaseLocation.dbPathIn(targetDir));
    if (existingDb.existsSync()) {
      final useExisting = await _askAboutExistingDb(existingDb.path);
      if (useExisting == null || !mounted) return;
      if (useExisting) {
        _setBusy('正在切换…');
        try {
          await DatabaseLocation.writeConfiguredDir(targetDir.path);
        } catch (e) {
          if (!mounted) return;
          _clearBusy();
          _toast('写入配置失败：$e');
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
      _toast('切换失败：$e');
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
      _toast('已记录。请手动关闭并重新打开 App 完成切换。');
      return;
    }
    final ok = await AppRestart.restart();
    if (!ok && mounted) {
      _toast('当前平台不支持自动重启，请手动关闭再打开 App。');
    }
  }

  // ==========================================================================
  // 清空 AI 历史
  // ==========================================================================

  Future<void> _clearAiHistory() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空 AI 历史'),
        content: const Text(
          '将删除全部 AI 调用记录：每次调用的任务类型、模型、'
          'token 用量与估算成本。\n'
          '笔记正文、笔记库、卡片流预留都不受影响。',
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
    _toast('已清空');
  }
}
