import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;

import '../app_info.dart';
import '../db/app_database.dart';
import '../db/database_location.dart';
import 'backup_models.dart';
import 'pending_import.dart';

/// 备份与恢复。
///
/// 三条硬性要求（来自实际会踩的坑）：
///
/// 1. **快照必须一致性**。导出用 SQLite 的 `VACUUM INTO`，不用 `File.copy`。
///    App 正在运行，主库文件随时可能被写到一半；直接拷贝会得到一个
///    少了最后一次提交、甚至撕裂的库。`VACUUM INTO` 由 SQLite 自己保证一致性。
///
/// 2. **导入必须能反悔**。换库之前先把当前库备份好；用户选了外部位置但
///    写不进去时，要如实报错而不是"表面成功、其实东西还在私有目录"。
///
/// 3. **不加密、不藏数据**。备份就是普通 zip，里面是标准 SQLite 文件，
///    用任何解压软件和 DB 工具都能打开看。
class BackupService {
  BackupService(this._db);

  final AppDatabase _db;

  /// 私有目录下自动留档的子目录名。

  /// 导入前旧库的备份子目录名。
  static const safetyFolder = 'backups';

  // ==========================================================================
  // 导出
  // ==========================================================================

  /// 导出到用户选定的位置。
  ///
  /// [primaryPath] 必须是**完整文件路径**（含 .zip）。目录由调用方（UI）
  /// 通过系统选目录对话框得到后拼好传进来——把「选目录」和「拼文件名」
  /// 分开，是为了让本方法可以在测试里直接用临时路径调用。
  ///
  /// **只在 [primaryPath] 生成一份**。这里刻意**不再**往 App 私有目录另留一份
  /// （早先会留）：用户没要的副本会一直堆在私有目录里，既占空间，
  /// 又让人以为"导出成功 = 系统里有两份"，而其中一份他根本找不到。
  Future<ExportOutcome> exportTo(String primaryPath) async {
    final stats = await _collectStats();

    // 1) 在私有目录生成一致性快照（不要直接写到用户选的位置：
    //    万一半路失败，用户笔记库里就会留下一个半截文件）
    final staging = await _newStagingDir('export');
    try {
      final snapshot = File(p.join(staging.path, kDatabaseFileName));
      await _db.snapshotTo(snapshot.path);
      if (!snapshot.existsSync() || snapshot.lengthSync() == 0) {
        throw StateError('数据库快照生成失败（文件为空）');
      }

      // 2) 组装备份包
      final archive = Archive();
      final bytes = await snapshot.readAsBytes();
      archive.addFile(ArchiveFile.bytes(kBackupDbEntryPath, bytes));

      final manifest = BackupManifest(
        formatVersion: kBackupFormatVersion,
        appName: kAppDisplayName,
        appVersion: kAppVersion,
        schemaVersion: kCurrentSchemaVersion,
        createdAt: DateTime.now().toUtc(),
        sourcePlatform: Platform.operatingSystem,
        stats: stats,
        files: [
          BackupFileEntry(
            path: kBackupDbEntryPath,
            size: bytes.length,
            sha256: sha256.convert(bytes).toString(),
          ),
        ],
      );
      archive.addFile(
        ArchiveFile.string(kBackupManifestPath, manifest.encode()),
      );

      // 3) 写目标文件。先写 .tmp 再改名：中途失败不会留下一个"看起来能用"
      //    但其实是半截的备份。
      final target = File(primaryPath);
      final parent = target.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      final tmp = File('${target.path}.tmp');
      final encoded = ZipEncoder().encodeBytes(archive);
      await tmp.writeAsBytes(encoded, flush: true);
      if (target.existsSync()) target.deleteSync();
      tmp.renameSync(target.path);

      return ExportOutcome(
        primaryPath: target.path,
        sizeBytes: encoded.length,
        stats: stats,
      );
    } finally {
      _deleteQuietly(staging);
    }
  }

  /// 生成默认的备份文件名，形如 `LightNote-20260213-1045.zip`。
  static String defaultArchiveName([DateTime? now]) {
    final t = (now ?? DateTime.now()).toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'LightNote-${t.year}${two(t.month)}${two(t.day)}'
        '-${two(t.hour)}${two(t.minute)}.zip';
  }



  /// 把当前库的一致性快照写到指定路径（文件必须不存在）。
  ///
  /// 给「切换工作目录」用：换目录本质上就是"把库搬到新位置"，
  /// 搬迁用的必须是快照而不是文件拷贝，理由见本文件顶部注释。
  Future<void> snapshotToNewFile(String targetPath) async {
    final target = File(targetPath);
    if (target.existsSync()) {
      throw BackupException(
        '目标位置已存在数据库文件，未做任何改动：\n$targetPath\n'
        '请选一个空笔记库，或先把那个文件移走。',
      );
    }
    final parent = target.parent;
    if (!parent.existsSync()) parent.createSync(recursive: true);
    await _db.snapshotTo(targetPath);
  }

  // ==========================================================================
  // 导入：第一步——校验，不动任何数据
  // ==========================================================================

  /// 检查一个 zip 是不是可用的备份包。
  ///
  /// 这一步**只读不写**。任何失败都抛 [BackupException]，由 UI 直接展示。
  /// 分三层校验，出问题的粒度越细，用户越容易判断该怎么办：
  ///   1. zip 能否解开、清单是否存在且合法；
  ///   2. 数据库条目是否存在、大小与 SHA-256 是否与清单一致；
  ///   3. 数据库本身是否完整（`PRAGMA integrity_check`）且版本兼容。
  Future<ImportPreview> inspect(String archivePath) async {
    final file = File(archivePath);
    if (!file.existsSync()) {
      throw BackupException('找不到文件：$archivePath');
    }

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(await file.readAsBytes());
    } catch (e) {
      throw BackupException('这个文件不是有效的 zip 压缩包（$e）');
    }

    final manifestFile = archive.findFile(kBackupManifestPath);
    if (manifestFile == null) {
      throw BackupException(
        '压缩包里没有 $kBackupManifestPath，不像是 LightNote 的备份包。',
      );
    }

    final BackupManifest manifest;
    try {
      final raw = jsonDecode(utf8.decode(manifestFile.content));
      if (raw is! Map) throw const FormatException('清单不是 JSON 对象');
      manifest = BackupManifest.fromJson(raw.cast<String, Object?>());
    } catch (e) {
      throw BackupException('备份清单无法解析（$e）');
    }

    final problem = manifest.compatibilityProblem(kCurrentSchemaVersion);
    if (problem != null) throw BackupException(problem);

    // 数据库条目：优先用清单里记录的路径，兼容将来可能存在的多条目录数据
    final entryPath = manifest.files.isNotEmpty
        ? manifest.files.first.path
        : kBackupDbEntryPath;
    final dbEntry = archive.findFile(entryPath) ??
        archive.findFile(kBackupDbEntryPath);
    if (dbEntry == null) {
      throw BackupException('压缩包里找不到数据库文件（$entryPath）');
    }

    final dbBytes = dbEntry.content;
    if (dbBytes.length < 100) {
      throw BackupException('数据库文件异常小（${dbBytes.length} 字节），可能已损坏');
    }

    // 校验和：清单里记了就必须对得上
    final expectedList = manifest.files
        .where((f) => f.path == entryPath || f.path == kBackupDbEntryPath)
        .map((f) => f.sha256)
        .toList();
    if (expectedList.isNotEmpty && expectedList.first.isNotEmpty) {
      final expected = expectedList.first;
      final actual = sha256.convert(dbBytes).toString();
      if (actual != expected) {
        throw BackupException(
          '数据库校验和不匹配，文件可能已损坏或传输不完整。\n'
          '期望 $expected\n实际 $actual',
        );
      }
    }

    // SQLite 文件头：53 51 4C 69 74 65 20 66 6F 72 6D 61 74 20 33 00
    const magic = 'SQLite format 3';
    if (!_startsWithAscii(dbBytes, magic)) {
      throw BackupException('数据库文件头不是 SQLite 格式，无法导入。');
    }

    // 真正打开一次，跑 integrity_check。
    // 只靠文件头不足以判断——“能打开但内容坏了”的库导入后会让 App 崩在运行时。
    await _verifySqliteIntegrity(dbBytes, manifest.schemaVersion);

    return ImportPreview(
      archivePath: archivePath,
      manifest: manifest,
      dbEntry: entryPath,
    );
  }

  /// 把 zip 中的数据库解出来，做一次真实的完整性检查。
  Future<void> _verifySqliteIntegrity(List<int> dbBytes, int schemaVersion) async {
    final staging = await _newStagingDir('verify');
    try {
      final candidate = File(p.join(staging.path, kDatabaseFileName));
      await candidate.writeAsBytes(dbBytes, flush: true);

      // 用 drift 自己的 NativeDatabase 打开，等同于生产路径，
      // 而不是另找一个可能行为不同的 sqlite 客户端。
      final probe = AppDatabase.forTesting(
        NativeDatabase(candidate, logStatements: false),
      );
      try {
        final rows = await probe
            .customSelect('PRAGMA integrity_check')
            .get()
            .timeout(const Duration(seconds: 30));
        final verdicts = rows.map((r) => r.read<String>('integrity_check')).toList();
        if (verdicts.length != 1 || verdicts.first.toLowerCase() != 'ok') {
          throw BackupException(
            '数据库完整性检查未通过：${verdicts.join('; ')}',
          );
        }

        final versionRows =
            await probe.customSelect('PRAGMA user_version').get();
        final version =
            versionRows.isEmpty ? 0 : versionRows.first.read<int>('user_version');
        if (version > schemaVersion) {
          throw BackupException(
            '备份的数据库版本（$version）高于本 App 支持的版本（$schemaVersion）。',
          );
        }

        // 关键表是否都在。缺表说明这不是本 App 的库，或者结构被改过。
        //
        // `notebooks` 与 `folders` 都接受：v3 把表从 folders 改名成了
        // notebooks，而**老备份包里仍然是 folders**。不必在这里改名——
        // 导入后由 v2→v3 的迁移统一执行
        // `ALTER TABLE folders RENAME TO notebooks`，那是唯一改名入口。
        //
        // 只认 notebooks 会让所有老备份被误判成"不是有效的笔记数据库"。
        final tables = await probe
            .customSelect(
              "SELECT name FROM sqlite_master WHERE type='table'",
            )
            .get();
        final names = tables.map((r) => r.read<String>('name')).toSet();
        // 只要求这几张表。
        //
        // 早先还要求 `cards`，但记忆卡片功能已删除、**新备份里不再有这张表**，
        // 继续要求它会让每一个新备份都被自己判定为"不是有效的笔记数据库"。
        // 老备份包多带的 `cards` / `reviews` 表不影响校验（导入后由 v6 迁移删掉）。
        if (!names.contains('notes')) {
          throw BackupException('备份里缺少数据表 `notes`，不是有效的笔记数据库。');
        }
        // ⚠️ key-value 表在 v9 从 `settings` 改名成了 `app_kv`（原先那个名字里
        // 10 个 key 有 6 个根本不是"设置"）。**必需表清单必须跟着改用新名**，
        // 否则新导出的备份会被自己判定成"不是有效的笔记数据库"
        // ——这个坑在 `folders` → `notebooks` 那次已经踩过一回。
        //
        // 按同一先例**同时接受旧名**：老备份包里仍然是 `settings`，
        // 导入后由 v8→v9 的 RENAME 统一改名。只认新名会把所有老备份挡在门外。
        if (!names.contains('app_kv') && !names.contains('settings')) {
          throw BackupException(
            '备份里缺少数据表 `app_kv`（或旧版的 `settings`），不是有效的笔记数据库。',
          );
        }
        if (!names.contains('notebooks') && !names.contains('folders')) {
          throw BackupException(
            '备份里缺少数据表 `notebooks`（或旧版的 `folders`），不是有效的笔记数据库。',
          );
        }
      } finally {
        await probe.close();
      }
    } finally {
      _deleteQuietly(staging);
    }
  }

  // ==========================================================================
  // 导入：第二步——安排在下次启动时换库
  // ==========================================================================

  /// 把导入任务写成「待处理」，返回提示文案。
  ///
  /// 为什么不在当前进程里直接换库：
  /// 数据库已经打开，Windows 上文件被占用根本换不掉；即使换掉了，
  /// 已经打开的连接指向的是旧 inode，接下来的读写会落到一个"已删除"的文件上。
  /// 所以换库统一放在下次启动、**连接建立之前**做（见 [PendingImport]）。
  Future<PendingImport> scheduleImport(
    ImportPreview preview, {
    ImportStrategy strategy = ImportStrategy.replace,
  }) async {
    final pending = PendingImport.create(
      archivePath: preview.archivePath,
      strategy: strategy,
      stats: preview.manifest.stats,
      importedAt: DateTime.now().toUtc(),
    );
    await pending.write();
    return pending;
  }

  // ==========================================================================
  // 统计
  // ==========================================================================

  Future<BackupStats> _collectStats() async {
    Future<int> count(String table) async {
      final rows =
          await _db.customSelect('SELECT COUNT(*) AS c FROM $table').get();
      return rows.isEmpty ? 0 : rows.first.read<int>('c');
    }

    return BackupStats(
      notes: await count('notes'),
      notebooks: await count('notebooks'),
    );
  }
  // ==========================================================================
  // 工具
  // ==========================================================================

  Future<Directory> _newStagingDir(String label) async {
    final root = await DatabaseLocation.privateRoot();
    final dir = Directory(
      p.join(root.path, 'staging', '$label-${DateTime.now().microsecondsSinceEpoch}'),
    );
    dir.createSync(recursive: true);
    return dir;
  }

  static bool _startsWithAscii(List<int> bytes, String text) {
    if (bytes.length < text.length) return false;
    for (var i = 0; i < text.length; i++) {
      if (bytes[i] != text.codeUnitAt(i)) return false;
    }
    return true;
  }

  static void _deleteQuietly(Directory dir) {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {
      // 清理临时目录失败不影响结果，留给系统清理
    }
  }
}

/// 备份相关失败。带用户可读的中文原因。
class BackupException implements Exception {
  BackupException(this.message, {this.detail});

  final String message;
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message\n$detail';
}
