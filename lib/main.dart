import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app/app_shell.dart';
import 'app/seed_bootstrap.dart';
import 'core/app_info.dart';
import 'core/backup/backup_models.dart';
import 'core/backup/backup_service.dart';
import 'core/backup/file_dialogs.dart';
import 'core/backup/pending_import.dart';
import 'core/db/app_database.dart';
import 'core/db/database_location.dart';
import 'core/prefs/preferences_service.dart';
import 'core/theme/app_theme.dart';
import 'core/widgets/log_bar.dart';
import 'features/ai/data/deepseek_client.dart';
import 'features/ai/domain/ai_chat_repository.dart';
import 'features/ai/domain/ai_repository.dart';
import 'features/note/data/feed_repository.dart';
import 'features/note/data/notebook_repository.dart';
import 'features/note/data/note_repository.dart';
import 'features/note/data/search_service.dart';

/// 启动时是否有待处理的导入。
///
/// 用全局变量而不是 Provider：它必须在 `AppDatabase()` 构造**之前**就确定，
/// 也就是在任何 Widget 树存在之前。UI 层只读它来做提示。
ImportOutcome? gStartupImport;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 顺序很关键：换库必须发生在任何数据库连接建立之前。
  // 这里只做纯文件操作，不碰 drift，所以不会有文件被占用的问题。
  try {
    gStartupImport = await applyPendingImportIfAny();
  } catch (e) {
    // 启动阶段的导入失败不能挡住 App 启动：
    // 用户宁可打开一个"旧数据还在"的 App，也不要看着它起不来。
    debugPrint('[LightNote] 待处理导入执行失败：$e');
    gStartupImport = null;
  }

  // 把数据库的真实位置写出来给构建脚本读。
  // 目的：让「编译 + 启动」时能直接在终端看到数据在哪，
  // 不用去翻日志或猜 AppData 的目录名。
  // 失败不影响启动，静默即可。
  unawaited(_publishDbLocation());

  runApp(const LightNoteApp());
}

/// 把数据库位置摘要写到 **App 工作目录**（= exe 所在目录）下的
/// `.lightnote-storage.txt`。
///
/// 这不是给 App 用的，是给**启动它的外部程序**读的：
/// 启动之后，外部程序可以去 exe 目录读这个文件，把"数据到底在哪"打印出来。
///
/// 为什么写在工作目录而不是工程根目录：App 不该知道自己被放在
/// 工程的哪个位置（Release 版会被整个拷到别处单独运行）。
/// 工作目录是启动方决定的，启动方正好知道它（就是 exe 所在目录）。
Future<void> _publishDbLocation() async {
  try {
    final info = await DatabaseLocation.describeSafe();
    final lines = <String>[
      'path=${info.activeDir}',
      'private=${info.isPrivate}',
      'unusable=${info.isUnusable}',
      'degradedProgramDir=${info.isDegradedToProgramDir}',
      if (info.isFallback) 'fallback=${info.fallbackNote ?? ''}',
      if (info.isEnvOverridden) 'envOverride=true',
      // 这几个是排查"degraded 标记为什么没置上"用的，正常看不出问题就删掉
      'exeDir=${File(Platform.resolvedExecutable).parent.path}',
      'exePath=${Platform.resolvedExecutable}',
      'privateUnavailable=${info.privateRootUnavailable}',
    ];
    // 先写临时文件再改名：脚本可能正好在这一刻去读，
    // 直接覆盖会读到写了一半的内容（脚本会当成解析失败）。
    final tmp = File('$kLocationReportFile.tmp');
    await tmp.writeAsString(lines.join('\n'), flush: true);
    final target = File(kLocationReportFile);
    if (target.existsSync()) await target.delete();
    await tmp.rename(target.path);
  } catch (e) {
    // 写不出来无所谓，只是个提示信息
    debugPrint('写位置报告失败：$e');
  }
}

/// 位置报告的文件名（相对 App 工作目录）。
const kLocationReportFile = '.lightnote-storage.txt';

class LightNoteApp extends StatelessWidget {
  const LightNoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 依赖装配集中在这里。规模变大后可换成 get_it 之类的容器，
    // 但在这个体量下 MultiProvider 更直观且无额外依赖。
    return MultiProvider(
      providers: [
        Provider<AppDatabase>(
          create: (_) => AppDatabase(),
          dispose: (_, db) => db.close(),
        ),
        Provider<DeepSeekClient>(create: (_) => DeepSeekClient()),
        Provider<FileDialogs>(create: (_) => FileDialogs.instance),

        // ---- 仓储层 ----
        ProxyProvider<AppDatabase, NotebookRepository>(
          update: (_, db, previous) => previous ?? NotebookRepository(db),
        ),
        ProxyProvider<AppDatabase, NoteRepository>(
          update: (_, db, previous) => previous ?? NoteRepository(db),
        ),
        // 统一搜索：搜索页与 AI 的 searchNotes 工具共用同一个实例
        ProxyProvider<AppDatabase, SearchService>(
          update: (_, db, previous) => previous ?? SearchService(db),
        ),
        ProxyProvider<AppDatabase, PreferencesService>(
          update: (_, db, previous) => previous ?? PreferencesService(db),
        ),
        ProxyProvider<AppDatabase, BackupService>(
          update: (_, db, previous) => previous ?? BackupService(db),
        ),
        ProxyProvider2<AppDatabase, DeepSeekClient, AiRepository>(
          update: (_, db, client, previous) =>
              previous ?? AiRepository(db: db, client: client),
        ),
        // FeedRepository 依赖 AiRepository，必须排在它后面。
        // Provider 是惰性解析的：写在前面会在第一次读取时抛
        // "Could not find the correct Provider<AiRepository>"。
        ProxyProvider2<AppDatabase, AiRepository, FeedRepository>(
          update: (_, db, ai, previous) =>
              previous ?? FeedRepository(db, ai),
        ),
        ProxyProvider2<AppDatabase, AiRepository, AiChatRepository>(
          update: (_, db, ai, previous) =>
              previous ?? AiChatRepository(db: db, ai: ai),
        ),
      ],
      // AI 初始化（读取已保存的 API Key）放在首帧之后，
      // 不阻塞启动，也不需要在 main 里 await。
      child: const _AppShell(),
    );
  }
}

class _AppShell extends StatefulWidget {
  const _AppShell();

  @override
  State<_AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<_AppShell> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AiRepository>().init();
      _announceStartupImportIfAny();
    });
  }

  /// 启动时刚完成过一次导入的话，必须明确告诉用户。
  ///
  /// 否则用户看到的是"我点了导入，然后 App 重启，数据好像变了又好像没变"——
  /// 换库这种破坏性操作，沉默是最糟的反馈方式。
  void _announceStartupImportIfAny() {
    final result = gStartupImport;
    if (result == null) return;
    gStartupImport = null;

    LogBar.action(
      context,
      '已从备份恢复：${result.stats.summary}'
      '${result.previousBackupPath == null ? '' : '\n旧数据已留档：${result.previousBackupPath}'}',
      actionLabel: '知道了',
      // 这条**要保持常驻**：内容里有"旧数据留档在哪个路径"，
      // 用户可能要照着这个路径去找文件，3 秒自动消失等于没告诉。
      // LogBar.action 的默认值就是 persist: true，这里显式写出来，
      // 免得以后有人顺手改成 false。
      persist: true,
    );
    // 提示只该出现一次
    clearLastImportNote();
  }

  @override
  Widget build(BuildContext context) {
    final prefs = context.read<PreferencesService>();

    return StreamBuilder<String>(
      stream: prefs.watchThemeMode().handleError((Object _) => 'system'),
      builder: (context, snapshot) {
        final mode = switch (snapshot.data) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          _ => ThemeMode.system,
        };

        return MaterialApp(
          title: kAppDisplayName,
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: mode,
          // 数据库打不开时不要只留一个转圈的空白壳：
          // 用户会以为"App 卡住了"，而真正原因（目录不可写）却看不到。
          home: const _StartupGate(child: HomeShell()),
        );
      },
    );
  }
}

/// 启动前的最后一道检查：确认数据库真的能打开。
///
/// 大多数环境会直接通过（一次 FutureBuilder 的开销，用户看不到）。
/// 只有私人目录全都不可写时才会显示诊断页——那种情况下必须把
/// 「试过哪些路径、各自什么错」原样摆出来，否则用户只能瞎猜。
class _StartupGate extends StatefulWidget {
  const _StartupGate({required this.child});

  final Widget child;

  @override
  State<_StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<_StartupGate> {
  late Future<void> _ready;

  @override
  void initState() {
    super.initState();
    _ready = _probe();
  }

  Future<void> _probe() async {
    // 只做一次极轻量的查询：真正触发 LazyDatabase 建库与迁移。
    // 这样失败会在这里被抓住，而不是在某个页面的 StreamBuilder 里炸开。
    final db = context.read<AppDatabase>();
    await db.customSelect('SELECT 1').get();

    // 示例数据必须在**任何页面构建之前**写好。
    //
    // 挂在页面上（比如某个页的 _bootstrap）不行：轻笔记页是消费流、要从库里
    // 抽卡片，首屏就需要笔记库已存在，挂到页面上会让首屏看起来是空的。
    // 示例数据属于启动职责。
    //
    // 写失败不抛（SeedBootstrap 内部已 try/catch）：宁可空库也要能启动。
    await SeedBootstrap.run(
      notes: context.read<NoteRepository>(),
      notebooks: context.read<NotebookRepository>(),
      prefs: context.read<PreferencesService>(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _ready,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.hasError) {
          return _StartupErrorScreen(error: snap.error!);
        }        return widget.child;
      },
    );
  }
}

class _StartupErrorScreen extends StatelessWidget {
  const _StartupErrorScreen({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.folder_off_outlined,
                  size: 40,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  '打不开本地数据库',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                Text(
                  'App 需要一个可写的目录来存放笔记数据库，但所有候选位置都失败了。\n'
                  '这不是数据丢失：原来的数据库文件仍然在磁盘上，'
                  '只是这次没能访问到它。\n\n'
                  '常见原因：\n'
                  '· 磁盘已满或为只读\n'
                  '· 安全软件/企业策略拦截了 AppData 与文档目录\n'
                  '· 以受限账户运行',
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.7),
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SelectableText(
                    '$error',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(fontFamily: 'monospace', height: 1.6),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '临时办法：设置环境变量 $DatabaseLocation.envOverride '
                  '指向一个确定可写的目录，然后重新启动 App。',
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
