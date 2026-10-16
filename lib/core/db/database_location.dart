import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 数据库文件名。
///
/// 统一叫 `lightnote.sqlite`，与 Dart 包名 `lightnote`、
/// Android 包名 `com.lightnote.app` 保持一致。
///
/// 但**发布过正式版之后这个名字就不能再改**：改文件名等于让所有老用户的
/// 数据库"凭空消失"（App 会在新路径建一个空库，旧文件变成孤儿）。
/// 现在还没有对外发布过正式版本，所以趁早统一；一旦发布即冻结，
/// 和 [kBackupDbEntryPath] 一起改（两处必须同步，否则导入备份会找不到库）。
const kDatabaseFileName = 'lightnote.sqlite';

/// 当前数据库结构版本。
///
/// 单独提出来是给备份/恢复用的：`BackupService` 需要在不构造 `AppDatabase`
/// 的前提下知道版本号，才能判断一个备份包是否兼容。
/// **改 `AppDatabase.schemaVersion` 时必须同步改这里**，
/// 两处不一致会导致"能导入但打不开"。
///
/// 版本历史：
///   1  初版
///   2  新增 note_feed_state（笔记消费流）；修正 is_inbox=false 且无笔记库的笔记
///   3  `folders` 改名 `notebooks` 并**去掉层级**（删 parent_id）；
///      `notes.folder_id` 改名 `notebook_id`（语义改为"所属笔记库"）
///   4  新增 note_ai_summaries（每篇笔记的 AI 摘要，持久化）；
///      同批建的 note_ai_tags 已在 v8 删除
///   5  新增 feed_reserve（轻笔记跨启动预留：上次留几张给下次秒出）
///   6  **删除记忆卡片相关表**（card_decks / cards / reviews）——
///      轻笔记卡片流取代了记忆卡片复习，这三张表已无任何读写方
///   7  **删除 note_summaries**（「AI 整理要点」的落库表）——
///      编辑页那个入口已移除；这张表一直只写不读，没有任何界面用它
///   8  **删除 note_feed_state / note_ai_tags** 两张死表——
///      前者是卡片流"复习已有笔记"时代的调度状态（改成 AI 生成新卡片后
///      就不适用了），后者是每篇笔记的 AI 标签（只写不读，卡片上显示的
///      标签其实来自卡片自己的 `FeedDraft.tag`）
///   9  **删除 tags / note_tags**（用户手动标签整条链路：写入只有编辑页那个
///      弹窗，读取只有它自己 + Markdown 导出里一行 `> 标签：`，产品确认不要）；
///      并改名两张表：`note_ai_summaries` → `ai_note_summaries`（跟同族的
///      ai_calls / ai_conversations 对齐）、`settings` → `app_kv`
///      （它 10 个 key 里有 6 个不是"设置"）
///   10 新增 note_chunks（笔记切片）
///   11 ai_conversations 新增 workspace_scope（工作区三态 JSON）
///   12 删除 ai_note_summaries（卡片流素材不再用摘要，改用一小段原文）
///   13 `ai_capabilities`（v1 遗留的死表）换成 `ai_functions`：
///      AI 的操作语言从「自定义命令脚本」改成 **SQL + UDF**，函数清单落库，
///      加函数 = INSERT 一行。老表没有任何读写方、必然是空的，直接删了重建。
///   14 ai_messages 新增 interrupt_reason（这条回答为什么没写完：网络断了 /
///      被系统杀了 / 轮数用尽……）。内容本来就一直在落库，这一列只回答
///      "写完了没有"，界面据此显示「未完成 + 继续」。
const kCurrentSchemaVersion = 18;

/// App 私有目录下的子目录名。
const kPrivateFolderName = 'LightNote';

/// 最后一档兜底时，在程序目录下用的数据目录名。
///
/// 以 `.` 开头：不干扰浏览，也天然被各种清理工具忽略。
const kProgramDirDataFolder = '.lightnote-data';

/// 存放"数据库位置"配置的文件名（放在私有目录，不是数据库里）。
const _configFileName = 'storage.json';

/// 环境变量名的对外别名，供 UI 与文档引用，避免各处硬编码字符串。
const kDbDirEnvOverride = DatabaseLocation.envOverride;

/// 数据库现在放在哪里。
class DatabaseLocationInfo {
  const DatabaseLocationInfo({
    required this.activeDir,
    required this.configuredDir,
    required this.isPrivate,
    required this.isFallback,
    required this.fallbackNote,
    this.isEnvOverridden = false,
    this.privateRootUnavailable = false,
    this.isUnusable = false,
    this.unusableReason,
    this.isDegradedToProgramDir = false,
    this.degradedNote,
  });

  /// 本次运行实际使用的目录。
  final String activeDir;

  /// 用户在设置里指定的工作目录；为 null 表示「用 App 私有目录」。
  final String? configuredDir;

  /// 是否在用 App 私有目录。
  final bool isPrivate;

  /// 是否发生了降级（指定的目录不可写，退回了别处）。
  final bool isFallback;

  /// 降级原因，用于在设置页如实告诉用户，而不是让他以为数据在新的位置上。
  final String? fallbackNote;

  /// 是否由环境变量 `LIGHTNOTE_DB_DIR` 指定（调试/CI 用）。
  final bool isEnvOverridden;

  /// 私有目录完全不可用（连候选位置都建不出来）。
  final bool privateRootUnavailable;

  /// 所有候选位置都不可用，数据库根本打不开。
  final bool isUnusable;

  /// [isUnusable] 为 true 时的原因全文（含每个候选各自的错误）。
  final String? unusableReason;

  /// 是否降级到了「程序所在目录」（在 `build\` 下面）。
  ///
  /// 这种情况要**重点警告**：数据在，但它在 `build\` 里，
  /// 一次 `flutter clean` 就会连数据一起删掉。
  final bool isDegradedToProgramDir;

  /// [isDegradedToProgramDir] 为 true 时，为什么其他位置都不可用。
  final String? degradedNote;
}

/// 工作目录的解析与切换。
///
/// 设计取舍（与需求对齐）：
///
/// 1. **默认私有**。Android 用 `getApplicationSupportDirectory`
///    （即 `/data/data/<包名>/files`），桌面用 `%APPDATA%\<包名>`。
///    用户不需要知道、也不应该去翻这个目录。
///
/// 2. **配置存在数据库之外**。想放在哪是个先有鸡还是先有蛋的问题：
///    如果"数据库位置"存在数据库里，那么在打开数据库之前根本读不到它。
///    所以在私有目录下放一个极小的 `storage.json` 作为锚点，
///    它永远只有几十字节，且不随工作目录变。
///
/// 3. **文件名固定为 `lightnote.sqlite`**（[kDatabaseFileName]）。位置随便换，
///    名字不跟着位置走——数据库搬到哪它都还叫这个名字。
///
/// 4. 所有路径都做**真实试写**再返回。目录存在 != 可写
///    （Android 上选到的目录可能是只读的 SAF 位置）。
class DatabaseLocation {
  DatabaseLocation._();

  /// 环境变量覆盖，优先级最高。调试 / CI / 自动化测试用。
  static const envOverride = 'LIGHTNOTE_DB_DIR';

  /// 本次运行实际使用的目录。由 `_openConnection` 在打开时写入。
  ///
  /// 缓存它而不是反复解析：一来避免每次读设置都重新试写文件，
  /// 二来保证"设置页显示的路径"与"数据库真正所在的路径"永远是同一个值。
  static Directory? _resolved;

  /// 已解析目录的缓存。
  static Directory? get resolvedDirectory => _resolved;

  /// 测试用：清空缓存，让下一次解析重新走一遍文件系统。
  static void resetCacheForTesting() {
    _resolved = null;
    _privateRoot = null;
  }

  /// 「用户主目录」的取法。**默认就是环境变量，只有测试会覆盖它**。
  ///
  /// 为什么需要这个缝：Dart 的 `Platform.environment` 是**只读**的，
  /// 而"所有常规私有目录都不可写 → 退到程序所在目录"这条路径要求
  /// **每一个**候选都不可写 —— 主目录也是候选之一。
  /// 测试改不了环境变量，只能把它一并指到死路上；不留这个缝，
  /// 测出来的会是"主目录赢了"，而不是那条兜底真的生效。
  static String Function() homeDirOf = defaultHomeDirOf;

  /// 默认取法（`USERPROFILE` → `HOME`）。
  ///
  /// 单独抽出来是为了让测试能**还原**：覆盖过的静态字段还原不回去的话，
  /// 会污染同一进程里后面所有用例（"我明明没改环境，怎么路径变了"）。
  static String defaultHomeDirOf() =>
      Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      '';

  /// 私有根目录的候选，按优先级排列。
  ///
  /// 之所以还要有第二、第三候选：`getApplicationSupportDirectory()` 在 Windows 上
  /// 是 `%APPDATA%\<公司名>\<产品名>`，并且 **path_provider 会顺手建这个目录**。
  /// 如果那个目录建不出来（企业策略收紧 AppData 权限、漫游配置损坏、
  /// 以受限令牌运行时），path_provider 会直接抛 PathAccessException。
  ///
  /// ⚠️ 必须逐个**真实试写**再决定，不能只包一层 try/catch 就退到「文档目录」：
  /// 那样在受限环境下数据会被写进**系统临时目录**（因为文档目录同样不可写），
  /// 用户重启一次电脑笔记就没了。失败原因会一路记到设置页，让用户知道自己的数据
  /// 到底在哪。
  static Future<List<({String label, Directory dir})>>
      _privateRootCandidates() async {
    final out = <({String label, Directory dir})>[];

    Future<void> add(String label, Future<Directory> Function() resolve) async {
      try {
        final base = await resolve();
        out.add((label: label, dir: Directory(p.join(base.path, kPrivateFolderName))));
      } catch (_) {
        // 连基础路径都解析不出来，这个候选直接作废
      }
    }

    await add('App 数据目录', getApplicationSupportDirectory);
    await add('文档目录', getApplicationDocumentsDirectory);

    // 第三候选：用户主目录。
    //
    // 走到这里说明前两个系统目录都建不出来（企业策略、受限令牌、漫游配置损坏）。
    // 用户主目录在这种环境下通常仍然可写，而且**不会被系统清理**。
    // 刻意不把「系统临时目录」列为候选：临时目录会在重启或磁盘清理时被删掉，
    // 把用户的笔记库放进去等于埋一个"过几天数据没了"的定时炸弹。
    final home = homeDirOf();
    if (home.trim().isNotEmpty) {
      out.add((
        label: '用户主目录',
        dir: Directory(p.join(home.trim(), kPrivateFolderName)),
      ));
    }

    // 第四候选（最后兜底）：可执行文件旁边。
    //
    // 走到这里说明 AppData、文档目录、用户主目录**全都建不出来**
    // （企业策略、应用虚拟化、受限令牌、只读漫游配置……）。
    // 与其让 App 变成一块只显示错误页的砖头，不如退到"程序自己所在的地方"：
    // 只要 App 能启动，它所在目录几乎一定是可读的，也通常可写。
    //
    // Android 排除：那里 resolvedExecutable 指向原生库目录（只读）。
    if (!Platform.isAndroid) {
      try {
        final exeDir = File(Platform.resolvedExecutable).parent;
        // 目录名以 . 开头：不干扰用户浏览，也天然被各种构建/清理工具忽略
        out.add((
          label: '程序所在目录',
          dir: Directory(p.join(exeDir.path, kProgramDirDataFolder)),
        ));
      } catch (_) {
        // resolvedExecutable 拿不到就算了
      }
    }

    return out;
  }

  /// App 私有根目录。
  ///
  /// 正常情况下就是 `getApplicationSupportDirectory()/LightNote`。
  /// 只有真的写不进去才退到备选位置；一旦确定，本次运行就固定下来
  /// （缓存），避免"这次读在 A、下次写在 B"。
  static Future<Directory> privateRoot() async {
    if (_privateRoot != null) return _privateRoot!;

    final failures = <String>[];

    for (final candidate in await _privateRootCandidates()) {
      final err = probeWritable(candidate.dir);
      if (err == null) {
        if (failures.isNotEmpty) {
          final detail = failures.join('\n  · ');
          // 记下来供设置页展示「为什么没落在常规位置」。
          // 注意**不能只在最后 throw 时记录**：退到程序目录这种情况
          // 是正常 return 的，不记的话警告里就没有原因可讲。
          _privateRootFailureNote = detail;
          // ignore: avoid_print
          print('[LightNote] 私有目录降级为「${candidate.label}」：'
              '${candidate.dir.path}\n  之前失败：$detail');
        }
        return _privateRoot = candidate.dir;
      }
      failures.add('${candidate.label} (${candidate.dir.path}): $err');
    }

    // 连临时目录都不试：临时目录会被系统清理，
    // 把用户的笔记库放进去等于埋一个"过几天数据没了"的定时炸弹。
    // 明确报错比静默丢数据好。
    final detail = failures.map((f) => '  · $f').join('\n');
    _privateRootFailureNote = detail;
    throw StateError(
      '找不到可写的私有数据目录，已尝试：\n$detail\n'
      '请检查磁盘空间与安全软件设置。',
    );
  }

  /// 已确定的私有根目录缓存。
  static Directory? _privateRoot;

  /// 配置文件的**锚点**候选，按优先级排列。
  ///
  /// ⚠️ 配置的存放点必须唯一且稳定，不能跟着数据目录一起漂。把 `storage.json`
  /// 放进「私有根目录」就不行：私有根目录是**按优先级逐档试出来的**
  /// （AppData → 文档 → 主目录 → 程序目录），于是配置的存放点会随环境漂移：
  ///
  ///   · 这次 AppData 能写 → 配置写在 AppData
  ///   · 下次 AppData 写不进去（权限变了、被清理了）→ 降级到文档目录，
  ///     它去**文档目录**找配置，而配置明明在 AppData 里 → 读不到 → 静默用默认位置
  ///
  /// 表现就是用户说的「我明明改过存储位置，怎么又没了」。
  ///
  /// 所以按优先级在这些固定锚点找/写配置：
  ///   1. **程序所在目录**——只要能启动 App 就一定能定位到，最可靠。
  ///      放在 `build\windows\x64\runner\Debug\storage.json`，
  ///      人一眼能找到，删了也知道删的是什么。
  ///   2. App 私有目录——Android 上用这个（exe 目录只读）；
  ///      桌面端作为兼容老位置的兜底。
  ///
  /// 读的时候逐个找（取第一个存在的），写的时候写第一个能写的。
  static Future<List<File>> configFileCandidates() async {
    final out = <File>[];

    // 1) 程序所在目录
    if (!Platform.isAndroid) {
      try {
        final exeDir = File(Platform.resolvedExecutable).parent;
        out.add(File(p.join(exeDir.path, _configFileName)));
      } catch (_) {
        // resolvedExecutable 拿不到就跳过
      }
    }

    // 2) App 私有目录（Android 的主力，桌面端的兼容位）
    try {
      final root = await privateRoot();
      final f = File(p.join(root.path, _configFileName));
      // 避免和上面重复
      if (!out.any((e) => p.equals(e.path, f.path))) out.add(f);
    } catch (_) {
      // 私有目录也拿不到就算了
    }

    return out;
  }

  /// 读取配置文件：按锚点优先级返回**第一个存在**的。
  ///
  /// 找不到时返回第一个锚点的路径，让调用方（诊断页）知道"该放哪"。
  static Future<File> configFile() async {
    final candidates = await configFileCandidates();
    if (candidates.isEmpty) {
      throw StateError('找不到任何可用于存放配置的位置');
    }
    for (final f in candidates) {
      if (f.existsSync()) return f;
    }
    return candidates.first;
  }

  /// 目标数据库文件的绝对路径（在给定目录下）。
  static String dbPathIn(Directory dir) =>
      p.join(dir.path, kDatabaseFileName);

  /// 读取已配置的工作目录；没配置或文件损坏都返回 null。
  static Future<String?> readConfiguredDir() async {
    List<File> candidates;
    try {
      candidates = await configFileCandidates();
    } catch (_) {
      return null;
    }

    // 逐个锚点找，取第一个能解析出内容的
    for (final f in candidates) {
      try {
        if (!f.existsSync()) continue;
        final raw = await f.readAsString();
        if (raw.trim().isEmpty) continue;
        final decoded = jsonDecode(raw);
        if (decoded is! Map) continue;
        final value = decoded['workingDir'];
        if (value is! String || value.trim().isEmpty) continue;
        return p.normalize(value.trim());
      } catch (_) {
        // 这个锚点的文件坏了，试下一个；
        // 绝不能抛异常：否则 App 直接打不开数据库。
        continue;
      }
    }
    return null;
  }

  /// 写入/清除工作目录配置。
  ///
  /// [dir] 传 null 表示恢复默认（App 私有目录）。
  ///
  /// 会**写到所有能写的锚点**：这样即使以后某个锚点变不可写、
  /// App 换了地方去找配置，也仍然能读到同一份设置。
  /// 返回实际写成功的路径（用于诊断展示）。
  static Future<List<String>> writeConfiguredDir(String? dir) async {
    final candidates = await configFileCandidates();
    final written = <String>[];

    for (final f in candidates) {
      try {
        final parent = f.parent;
        if (!parent.existsSync()) parent.createSync(recursive: true);

        if (dir == null || dir.trim().isEmpty) {
          if (f.existsSync()) f.deleteSync();
          written.add('${f.path}（已清除）');
          continue;
        }

        final payload = jsonEncode({
          'version': 1,
          'workingDir': p.normalize(dir.trim()),
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        });
        // 先写临时文件再改名：避免写一半掉电留下半个 JSON，
        // 下次启动就变成"配置损坏"，用户会以为数据丢了。
        final tmp = File('${f.path}.tmp');
        tmp.writeAsStringSync(payload, flush: true);
        if (f.existsSync()) f.deleteSync();
        tmp.renameSync(f.path);
        written.add(f.path);
      } catch (_) {
        // 这个锚点写不了（只读目录等），继续试下一个。
        // 至少有一个成功就够用。
        continue;
      }
    }

    if (written.isEmpty) {
      throw StateError(
        '无法写入配置，已尝试：\n'
        '${candidates.map((f) => '  · ${f.path}').join('\n')}',
      );
    }
    return written;
  }

  /// 试写一个探针文件，返回 null 表示可写，否则返回失败原因。
  ///
  /// 不用 `Directory.statSync().mode` 之类判断权限：Windows 的 ACL、
  /// Android 的 SAF、以及安全软件的拦截都不体现在 mode 上，
  /// 只有真的写一次才作数。
  static String? probeWritable(Directory dir) {
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final probe = File(p.join(dir.path, '.lightnote_write_probe'));
      probe.writeAsStringSync('ok', flush: true);
      probe.deleteSync();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// 解析本次要用的数据库目录。
  ///
  /// 顺序：环境变量 → 用户配置的工作目录 → App 私有目录。
  /// 任一环节失败都退到下一档，并把原因记在 [lastFallbackNote] 里，
  /// 让设置页能如实展示"你现在到底写在哪"。
  static String? lastFallbackNote;

  static Future<Directory> resolveDirectory() async {
    if (_resolved != null) return _resolved!;
    lastFallbackNote = null;

    // 1) 环境变量覆盖
    final env = Platform.environment[envOverride]?.trim();
    if (env != null && env.isNotEmpty) {
      final dir = Directory(p.normalize(env));
      final err = probeWritable(dir);
      if (err == null) return _resolved = dir;
      lastFallbackNote = '环境变量 $envOverride 指定的目录不可写（$err）';
    }

    // 2) 用户配置的工作目录
    final configured = await readConfiguredDir();
    if (configured != null) {
      final dir = Directory(configured);
      final err = probeWritable(dir);
      if (err == null) return _resolved = dir;
      lastFallbackNote =
          '${lastFallbackNote == null ? '' : '$lastFallbackNote；'}'
          '工作目录 $configured 不可写（$err）';
    }

    // 3) App 私有目录：默认，也是最后的保底
    final priv = await privateRoot();
    final err = probeWritable(priv);
    if (err == null) return _resolved = priv;

    // 私有目录都写不进去，这个环境已经不适合运行本 App 了。
    // 抛异常比"静默用临时目录"更好：临时目录会被系统清理，用户会静默丢数据。
    throw StateError(
      'App 私有目录不可写：${priv.path}\n原因：$err\n'
      '请检查磁盘空间与安全软件，或设置环境变量 $envOverride 指定一个可写目录。',
    );
  }

  /// 汇总当前状态，供设置页展示。
  ///
  /// 永远不抛异常：设置页、启动提示都只是"展示信息"，
  /// 绝不能因为解析位置失败就把界面打崩。
  /// 连候选目录全都不可用时也会返回一个 `isUnusable = true` 的结果。
  static Future<DatabaseLocationInfo> describeSafe() async {
    Directory active;
    try {
      active = await resolveDirectory();
    } catch (e) {
      // 一个都写不进去：返回一个"不可用"的结果，
      // 真正的诊断文字由调用方从 error 里取
      return DatabaseLocationInfo(
        activeDir: '(不可用)',
        configuredDir: await readConfiguredDir(),
        isPrivate: false,
        isFallback: false,
        fallbackNote: null,
        isUnusable: true,
        unusableReason: e.toString(),
      );
    }

    final configured = await readConfiguredDir();

    // 环境变量覆盖优先级最高，且它一定不是"私有目录"
    final env = Platform.environment[envOverride]?.trim();
    final hasEnvOverride = env != null &&
        env.isNotEmpty &&
        p.equals(p.normalize(env), active.path);

    Directory? priv;
    try {
      priv = await privateRoot();
    } catch (_) {
      priv = null;
    }

    final isPrivate = priv != null && p.equals(active.path, priv.path);
    final isFallback = configured != null && !p.equals(active.path, configured);

    // 「退到程序目录」是比 isFallback 更严重的一种情况，而且**判定不能挂在
    // isFallback 上**：没配置工作目录（configured == null）时 isFallback 为 false，
    // 但私有目录全不可用、最终落到 build\ 下面同样是危险状态。
    // 之前绑在一起，导致设置首页把这种情况显示成普通的「自定义目录」，
    // 丢失了"数据在 build\ 里、删 build 就没了"这个关键警告。
    final degradedToProgramDir = isFallbackToProgramDir(active);

    // 退化时把"为什么其他位置都不行"讲清楚；否则退回给 isFallback 的原因
    final degradeNote = degradedToProgramDir
        ? (lastFallbackNote ?? _privateRootFailureNote ?? '常规位置均不可写')
        : (isFallback ? lastFallbackNote : null);

    return DatabaseLocationInfo(
      activeDir: active.path,
      configuredDir: configured,
      isPrivate: isPrivate,
      isFallback: isFallback,
      fallbackNote: isFallback ? lastFallbackNote : null,
      isEnvOverridden: hasEnvOverride && !isPrivate,
      privateRootUnavailable: priv == null,
      isDegradedToProgramDir: degradedToProgramDir,
      degradedNote: degradeNote,
    );
  }

  /// 私有根目录解析失败时的原因（由 [privateRoot] 记录）。
  static String? _privateRootFailureNote;

  /// 判断是否降级到了「程序所在目录」（最后兜底，在 build\ 下面）。
  ///
  /// 这种情况必须**显式警告**：数据虽然在，但它在 `build\` 里，
  /// 一次 `flutter clean` 或手工删 `build\` 就会连数据一起没。
  static bool isFallbackToProgramDir(Directory dir) {
    if (Platform.isAndroid) return false;
    try {
      final exeDir = File(Platform.resolvedExecutable).parent;
      final marker = p.join(exeDir.path, kProgramDirDataFolder);
      return p.equals(p.normalize(dir.path), p.normalize(marker));
    } catch (_) {
      return false;
    }
  }

  // ==========================================================================
  // 诊断
  // ==========================================================================

  /// 把「数据库位置是怎么定下来的」整条链摊开成可读文本。
  ///
  /// 为什么需要它：位置解析有好几档（环境变量 → 用户配置 → 三个系统目录 →
  /// 程序目录），**每一档都可能失败**。出问题时只给一个最终路径根本没法判断
  /// 问题出在哪一段——是配置文件没读到？还是目录建不出来？
  /// 之前排查"数据到底在哪"就卡在这里。
  ///
  /// 这个方法把每一档的实际路径、试写结果、是否被采用全列出来，
  /// 出错页与设置页直接展示它。
  static Future<String> diagnose() async {
    final b = StringBuffer();
    final adopted = _resolved;

    b.writeln('数据库位置解析过程');
    b.writeln('');

    void verdict(String label, String path, String? err, bool used) {
      final mark = used
          ? '✅ 采用'
          : (err == null ? '·  可用但未采用' : '❌ 失败');
      b.writeln('$mark  $label');
      b.writeln('      $path');
      if (err != null) b.writeln('      $err');
    }

    // 1) 环境变量
    final env = Platform.environment[envOverride]?.trim();
    if (env == null || env.isEmpty) {
      b.writeln('·  未设置环境变量 $envOverride');
    } else {
      final dir = Directory(p.normalize(env));
      final err = probeWritable(dir);
      verdict('环境变量 $envOverride', dir.path, err,
          adopted != null && p.equals(adopted.path, dir.path));
    }
    b.writeln('');

    // 2) 用户配置的工作目录
    String? configured;
    String? cfgPath;
    try {
      final f = await configFile();
      cfgPath = f.path;
      configured = await readConfiguredDir();
    } catch (e) {
      b.writeln('❌ 读取配置文件失败：$e');
    }
    if (cfgPath != null) {
      b.writeln('配置文件：$cfgPath');
      b.writeln('  存在：${File(cfgPath).existsSync()}');
    }
    if (configured == null) {
      b.writeln('·  未配置工作目录（用默认位置）');
    } else {
      final dir = Directory(configured);
      final err = probeWritable(dir);
      verdict('用户配置的工作目录', dir.path, err,
          adopted != null && p.equals(adopted.path, dir.path));
    }
    b.writeln('');

    // 3) 各私有目录候选
    b.writeln('私有目录候选（按顺序试写）：');
    try {
      for (final c in await _privateRootCandidates()) {
        final err = probeWritable(c.dir);
        verdict(c.label, c.dir.path, err,
            adopted != null && p.equals(adopted.path, c.dir.path));
      }
    } catch (e) {
      b.writeln('  ❌ 枚举候选时失败：$e');
    }

    b.writeln('');
    b.writeln('最终采用：${adopted?.path ?? '(尚未解析)'}');
    final note = lastFallbackNote;
    if (note != null) {
      b.writeln('');
      b.writeln('降级原因：$note');
    }
    return b.toString();
  }
}
