import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/app_info.dart';
import 'core/db/app_database.dart';
import 'core/db/database_location.dart';
import 'core/theme/app_theme.dart';
import 'features/ai/data/deepseek_client.dart';
import 'features/ai/domain/ai_chat_repository.dart';
import 'features/ai/domain/ai_repository.dart';
import 'features/ai/ui/ai_page.dart';
import 'features/cards/domain/card_repository.dart';
import 'features/folders/data/folder_repository.dart';
import 'features/notes/data/note_repository.dart';
import 'features/notes/ui/inbox_page.dart';
import 'features/notes/ui/library_page.dart';
import 'features/settings/ui/settings_page.dart';
import 'services/backup/backup_models.dart';
import 'services/backup/backup_service.dart';
import 'services/backup/file_dialogs.dart';
import 'services/backup/pending_import.dart';
import 'services/markdown_export_service.dart';
import 'services/preferences_service.dart';

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

  runApp(const LightNoteApp());
}

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
        ProxyProvider<AppDatabase, FolderRepository>(
          update: (_, db, previous) => previous ?? FolderRepository(db),
        ),
        ProxyProvider<AppDatabase, NoteRepository>(
          update: (_, db, previous) => previous ?? NoteRepository(db),
        ),
        ProxyProvider<AppDatabase, CardRepository>(
          update: (_, db, previous) => previous ?? CardRepository(db),
        ),
        ProxyProvider<AppDatabase, PreferencesService>(
          update: (_, db, previous) => previous ?? PreferencesService(db),
        ),
        ProxyProvider<AppDatabase, MarkdownExportService>(
          update: (_, db, previous) => previous ?? MarkdownExportService(db),
        ),
        ProxyProvider<AppDatabase, BackupService>(
          update: (_, db, previous) => previous ?? BackupService(db),
        ),
        ProxyProvider2<AppDatabase, DeepSeekClient, AiRepository>(
          update: (_, db, client, previous) =>
              previous ?? AiRepository(db: db, client: client),
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

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 8),
        content: Text(
          '已从备份恢复：${result.stats.summary}'
          '${result.previousBackupPath == null ? '' : '\n旧数据已留档：${result.previousBackupPath}'}',
        ),
        action: SnackBarAction(
          label: '知道了',
          onPressed: messenger.hideCurrentSnackBar,
        ),
      ),
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
        }
        return widget.child;
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

/// 底部导航：轻笔记 / 笔记库 / AI / 设置（设计稿 §2）
///
/// 第 5 个入口「复习」是从最初需求里的记忆卡片功能来的，
/// 设计稿没有它，但删掉会丢掉 SM-2 复习这个核心能力，
/// 所以放在「笔记库」页的入口里，而不是挤进底部导航。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // IndexedStack 保留各页滚动位置与输入状态，切标签不会丢失上下文
      body: IndexedStack(
        index: _index,
        children: const [
          InboxPage(),
          LibraryPage(),
          AiPage(),
          SettingsPage(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.bolt_outlined),
            selectedIcon: Icon(Icons.bolt),
            label: '轻笔记',
          ),
          NavigationDestination(
            icon: Icon(Icons.library_books_outlined),
            selectedIcon: Icon(Icons.library_books),
            label: '笔记库',
          ),
          NavigationDestination(
            icon: Icon(Icons.auto_awesome_outlined),
            selectedIcon: Icon(Icons.auto_awesome),
            label: 'AI',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}
