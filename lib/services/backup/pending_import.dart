import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../../core/app_info.dart';
import '../../core/db/database_location.dart';
import 'backup_models.dart';

/// 「下次启动时完成的导入」。
///
/// 为什么要把换库推迟到下次启动：
///
/// 导入时数据库已经打开着。在 Windows 上，打开中的 sqlite 文件被占用，
/// 既不能改名也不能覆盖；就算强行换掉，已经建立的 drift 连接指向的还是旧文件，
/// 之后所有读写都会落到一个"已经不属于 App"的文件上——这类不一致
/// 比导入失败严重得多。
///
/// 所以这里的做法是：**导入只登记意图，换库在下次启动、连接建立之前做**。
/// 那段代码是纯文件操作，不涉及任何已打开的数据库，简单且不会失败。
///
/// 配套的启动钩子见 [applyPendingImportIfAny]，必须在 `AppDatabase()`
/// 构造之前调用（`main()` 里第一件事）。
class PendingImport {
  PendingImport._({
    required this.archivePath,
    required this.strategy,
    required this.stats,
    required this.importedAt,
    this.adoptWorkingDir,
  });

  final String archivePath;
  final ImportStrategy strategy;
  final BackupStats stats;
  final DateTime importedAt;

  /// 本次导入同时要把工作目录切到这里（选填）。
  final String? adoptWorkingDir;

  /// 待处理标记的文件名。放在私有根目录，不随工作目录改变。
  static const fileName = 'pending_import.json';

  static Future<File> file() async {
    final root = await DatabaseLocation.privateRoot();
    return File(p.join(root.path, fileName));
  }

  static PendingImport create({
    required String archivePath,
    required ImportStrategy strategy,
    required BackupStats stats,
    required DateTime importedAt,
    String? adoptWorkingDir,
  }) {
    return PendingImport._(
      archivePath: archivePath,
      strategy: strategy,
      stats: stats,
      importedAt: importedAt,
      adoptWorkingDir: adoptWorkingDir,
    );
  }

  Future<void> write() async {
    final f = await file();
    final parent = f.parent;
    if (!parent.existsSync()) parent.createSync(recursive: true);
    final payload = jsonEncode({
      'version': 1,
      'archivePath': archivePath,
      'strategy': strategy.name,
      'stats': stats.toJson(),
      'importedAt': importedAt.toIso8601String(),
      if (adoptWorkingDir != null) 'adoptWorkingDir': adoptWorkingDir,
    });
    // 先写临时文件再改名，避免半个 JSON 让下次启动无从判断
    final tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(payload, flush: true);
    if (f.existsSync()) f.deleteSync();
    tmp.renameSync(f.path);
  }

  Future<void> clear() async {
    final f = await file();
    if (f.existsSync()) f.deleteSync();
    final tmp = File('${f.path}.tmp');
    if (tmp.existsSync()) tmp.deleteSync();
  }

  /// 读取待处理标记；不存在或损坏都返回 null。
  static Future<PendingImport?> read() async {
    try {
      final f = await file();
      if (!f.existsSync()) return null;
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map) return null;
      final archive = raw['archivePath'];
      if (archive is! String || archive.isEmpty) return null;
      final strategy = ImportStrategy.values.firstWhere(
        (s) => s.name == raw['strategy'],
        orElse: () => ImportStrategy.replace,
      );
      return PendingImport._(
        archivePath: archive,
        strategy: strategy,
        stats: BackupStats.fromJson(raw['stats']),
        importedAt: DateTime.tryParse(raw['importedAt'] as String? ?? '') ??
            DateTime.now().toUtc(),
        adoptWorkingDir: raw['adoptWorkingDir'] as String?,
      );
    } catch (_) {
      // 标记坏了就当作没有待处理任务。
      // 绝不能因此让 App 启动失败——用户宁可丢掉一次导入，也不能打不开 App。
      return null;
    }
  }
}

// ============================================================================
// 启动阶段的执行逻辑
// ============================================================================

/// 启动时若有待处理的导入，就在这里把它真正落地。
///
/// 只能在 `AppDatabase()` 构造**之前**调用。
/// 整个过程不打开数据库，因此不存在文件占用问题。
///
/// 返回 null 表示没有待处理任务，或任务无法完成（例如备份文件已被移走）。
Future<ImportOutcome?> applyPendingImportIfAny() async {
  final pending = await PendingImport.read();
  if (pending == null) return null;

  // 先把标记清掉，再干活。这样即使中途失败也不会陷入
  // "每次启动都重试一遍"的循环——反复重试有可能把用户的库换成不完整的文件。
  await pending.clear();

  final archive = File(pending.archivePath);
  if (!archive.existsSync()) return null;

  final work = await _newWorkDir();
  try {
    // 1) 从 zip 里解出数据库。
    //    这里重新解压而不是复用导入时的校验结果：从"用户点确认"到
    //    "下次启动"之间，文件仍有可能被改过或损坏。
    final extracted = await _extractDatabase(archive, work);
    if (extracted == null) return null;

    // 2) 决定落到哪个目录
    final targetDir = await _resolveTargetDir(pending);
    if (!targetDir.existsSync()) targetDir.createSync(recursive: true);
    final target = File(DatabaseLocation.dbPathIn(targetDir));

    // 3) 目标已存在时先备份/改名，绝不静默覆盖
    String? previousBackup;
    if (target.existsSync()) {
      previousBackup = await _preserveExisting(target, pending.strategy);
    }

    // 4) 就位
    await _moveFile(extracted, target);

    // 5) 落配置
    if (pending.adoptWorkingDir != null) {
      await DatabaseLocation.writeConfiguredDir(pending.adoptWorkingDir);
    }
    await _writeLastImportNote(pending);

    return ImportOutcome(
      importedFrom: archive.path,
      stats: pending.stats,
      strategy: pending.strategy,
      previousBackupPath: previousBackup,
    );
  } finally {
    _deleteQuietly(work);
  }
}

/// 上次导入的结果，用于在 UI 上给用户一个"已经换好了"的反馈。
Future<Map<String, Object?>?> readLastImportNote() async {
  try {
    final root = await DatabaseLocation.privateRoot();
    final f = File(p.join(root.path, 'last_import.json'));
    if (!f.existsSync()) return null;
    final raw = jsonDecode(await f.readAsString());
    return raw is Map ? raw.cast<String, Object?>() : null;
  } catch (_) {
    return null;
  }
}

Future<void> clearLastImportNote() async {
  try {
    final root = await DatabaseLocation.privateRoot();
    final f = File(p.join(root.path, 'last_import.json'));
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}

// ============================================================================
// 内部实现
// ============================================================================

Future<Directory> _newWorkDir() async {
  final root = await DatabaseLocation.privateRoot();
  final dir = Directory(
    p.join(root.path, 'staging',
        'import-${DateTime.now().microsecondsSinceEpoch}'),
  );
  dir.createSync(recursive: true);
  return dir;
}

Future<Directory> _resolveTargetDir(PendingImport pending) async {
  final adopt = pending.adoptWorkingDir;
  if (adopt != null && adopt.trim().isNotEmpty) {
    final dir = Directory(p.normalize(adopt.trim()));
    if (DatabaseLocation.probeWritable(dir) == null) return dir;
    // 目标不可写就退回家目录：宁可换到默认位置，也不要让导入彻底失败
  }
  return DatabaseLocation.privateRoot();
}

Future<File?> _extractDatabase(File archive, Directory work) async {
  try {
    final Archive decoded;
    try {
      decoded = ZipDecoder().decodeBytes(await archive.readAsBytes());
    } catch (_) {
      return null;
    }
    final entry = decoded.findFile(kBackupDbEntryPath);
    if (entry == null) return null;
    final bytes = entry.content;
    if (bytes.length < 100) return null;
    final out = File(p.join(work.path, kDatabaseFileName));
    await out.writeAsBytes(bytes, flush: true);
    return out;
  } catch (_) {
    return null;
  }
}

/// 把已有数据库移到一边，返回它的新路径。
Future<String> _preserveExisting(File target, ImportStrategy strategy) async {
  if (strategy == ImportStrategy.keepBoth) {
    final sibling = File(
      p.join(target.parent.path, 'before-import-${_stamp()}.sqlite'),
    );
    await _moveFile(target, sibling);
    return sibling.path;
  }

  // replace：拷进 backups/ 目录，保留完整历史
  final root = await DatabaseLocation.privateRoot();
  final dir = Directory(p.join(root.path, 'backups'));
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final dest = File(p.join(dir.path, 'before-import-${_stamp()}.sqlite'));
  await target.copy(dest.path);
  return dest.path;
}

Future<void> _writeLastImportNote(PendingImport pending) async {
  try {
    final root = await DatabaseLocation.privateRoot();
    final f = File(p.join(root.path, 'last_import.json'));
    f.writeAsStringSync(
      jsonEncode({
        'importedFrom': pending.archivePath,
        'importedAt': DateTime.now().toUtc().toIso8601String(),
        'stats': pending.stats.toJson(),
        'strategy': pending.strategy.name,
        'appVersion': kAppVersion,
      }),
      flush: true,
    );
  } catch (_) {}
}

String _stamp() {
  final t = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}${two(t.month)}${two(t.day)}-'
      '${two(t.hour)}${two(t.minute)}${two(t.second)}';
}

/// 同分区 rename，跨分区 copy + delete。
///
/// 直接依赖 `renameSync` 会在"工作目录在 D 盘、私有目录在 C 盘"时抛
/// 跨设备错误，所以这里必须能退回复制。
Future<void> _moveFile(File from, File to) async {
  try {
    if (to.existsSync()) to.deleteSync();
    from.renameSync(to.path);
  } on FileSystemException {
    await from.copy(to.path);
    try {
      from.deleteSync();
    } catch (_) {}
  }
}

void _deleteQuietly(Directory dir) {
  try {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  } catch (_) {}
}
