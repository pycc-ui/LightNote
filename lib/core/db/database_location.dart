import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 数据库文件名。
///
/// 仍然是 `qing_notes.sqlite` 而不是 `lightnote.sqlite`：
/// 改文件名等于让所有老用户的数据库"凭空消失"（App 会在新路径建一个空库）。
/// 产品名可以改，数据库文件名一旦发布就不能改。
const kDatabaseFileName = 'qing_notes.sqlite';

/// 当前数据库结构版本。
///
/// 单独提出来是给备份/恢复用的：`BackupService` 需要在不构造 `AppDatabase`
/// 的前提下知道版本号，才能判断一个备份包是否兼容。
/// **改 `AppDatabase.schemaVersion` 时必须同步改这里**，
/// 两处不一致会导致"能导入但打不开"。
const kCurrentSchemaVersion = 1;

/// App 私有目录下的子目录名。
const kPrivateFolderName = 'LightNote';

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

  /// 是否由环境变量 `QING_NOTES_DB_DIR` 指定（调试/CI 用）。
  final bool isEnvOverridden;

  /// 私有目录完全不可用（连候选位置都建不出来）。
  final bool privateRootUnavailable;
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
/// 3. **不改文件名**。为兼容老数据，文件名保持 `qing_notes.sqlite`。
///
/// 4. 所有路径都做**真实试写**再返回。目录存在 != 可写
///    （Android 上选到的目录可能是只读的 SAF 位置）。
class DatabaseLocation {
  DatabaseLocation._();

  /// 环境变量覆盖，优先级最高。调试 / CI / 自动化测试用。
  static const envOverride = 'QING_NOTES_DB_DIR';

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

  /// 显式指定本次运行的目录（导入后无缝切换时使用）。
  static void setResolvedDirectory(Directory dir) => _resolved = dir;

  /// 私有根目录的候选，按优先级排列。
  ///
  /// 之所以还要有第二、第三候选：`getApplicationSupportDirectory()` 在 Windows 上
  /// 是 `%APPDATA%\<公司名>\<产品名>`，并且 **path_provider 会顺手建这个目录**。
  /// 如果那个目录建不出来（企业策略收紧 AppData 权限、漫游配置损坏、
  /// 以受限令牌运行时），path_provider 会直接抛 PathAccessException。
  ///
  /// 老版本代码在这里只做了一层 try/catch 就退到「文档目录」，
  /// 结果在受限环境下数据被写进了**系统临时目录**（因为文档目录同样不可写），
  /// 用户重启一次电脑笔记就没了。所以现在必须逐个**真实试写**再决定，
  /// 失败原因会一路记到设置页，让用户知道自己的数据到底在哪。
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
    // 把用户的笔记库放进去等于埋一个"过几天数据没了"的定时炸弹——
    // 报错让用户知道，永远好过静默丢数据。
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '';
    if (home.trim().isNotEmpty) {
      out.add((
        label: '用户主目录',
        dir: Directory(p.join(home.trim(), kPrivateFolderName)),
      ));
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
          // ignore: avoid_print
          print('[LightNote] 私有目录降级为「${candidate.label}」：'
              '${candidate.dir.path}\n  之前失败：${failures.join(' | ')}');
        }
        return _privateRoot = candidate.dir;
      }
      failures.add('${candidate.label} (${candidate.dir.path}): $err');
    }

    // 连临时目录都不试：临时目录会被系统清理，
    // 把用户的笔记库放进去等于埋一个"过几天数据没了"的定时炸弹。
    // 明确报错比静默丢数据好。
    throw StateError(
      '找不到可写的私有数据目录，已尝试：\n'
      '${failures.map((f) => '  · $f').join('\n')}\n'
      '请检查磁盘空间与安全软件设置。',
    );
  }

  /// 已确定的私有根目录缓存。
  static Directory? _privateRoot;

  /// 配置文件的绝对路径。总是位于私有目录，不随工作目录改变。
  static Future<File> configFile() async {
    final root = await privateRoot();
    return File(p.join(root.path, _configFileName));
  }

  /// 目标数据库文件的绝对路径（在给定目录下）。
  static String dbPathIn(Directory dir) =>
      p.join(dir.path, kDatabaseFileName);

  /// 读取已配置的工作目录；没配置或文件损坏都返回 null。
  static Future<String?> readConfiguredDir() async {
    try {
      final f = await configFile();
      if (!f.existsSync()) return null;
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final value = decoded['workingDir'];
      if (value is! String || value.trim().isEmpty) return null;
      return p.normalize(value.trim());
    } catch (_) {
      // 配置文件坏了就当作"没配置"，退回私有目录。
      // 这里绝不能抛异常：否则 App 直接打不开数据库。
      return null;
    }
  }

  /// 写入/清除工作目录配置。
  ///
  /// [dir] 传 null 表示恢复默认（App 私有目录）。
  static Future<void> writeConfiguredDir(String? dir) async {
    final root = await privateRoot();
    if (!root.existsSync()) root.createSync(recursive: true);
    final f = File(p.join(root.path, _configFileName));
    if (dir == null || dir.trim().isEmpty) {
      if (f.existsSync()) f.deleteSync();
      return;
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
  /// 注意这里**不能假设 privateRoot() 一定成功**：在私有目录全不可写的环境里，
  /// 数据库是靠 [envOverride] 跑起来的，此时 privateRoot() 会抛异常。
  /// 设置页只是"展示信息"，绝不能因此把整页打崩——所以每一段都单独容错。
  static Future<DatabaseLocationInfo> describe() async {
    final active = await resolveDirectory();
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
    return DatabaseLocationInfo(
      activeDir: active.path,
      configuredDir: configured,
      isPrivate: isPrivate,
      isFallback: configured != null && !p.equals(active.path, configured),
      // 只有"配置了工作目录却没生效"才叫降级。
      // 环境变量覆盖是调试手段，不该出现在正常用户的界面上。
      fallbackNote: (configured != null && !p.equals(active.path, configured))
          ? lastFallbackNote
          : null,
      isEnvOverridden: hasEnvOverride && !isPrivate,
      privateRootUnavailable: priv == null,
    );
  }

  /// 判断某个路径是否位于 App 私有目录内。
  ///
  /// 用于在 UI 上区分「私有（不用管）」和「你自己选的目录（要自己备份）」。
  static Future<bool> isInsidePrivate(String path) async {
    final priv = await privateRoot();
    final rel = p.relative(path, from: priv.path);
    return !rel.startsWith('..') && !p.isAbsolute(rel);
  }
}
