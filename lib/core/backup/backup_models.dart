/// 备份包的清单与格式定义。
///
/// 备份包就是一个普通 zip，任何人可以用资源管理器/解压软件打开检查，
/// 不加密、不私有格式——用户的数据不该被锁在一个只有本 App 能读的盒子里。
///
/// 目录结构：
/// ```
/// lightnote-backup-20260213-104500.zip
/// ├── backup.json                    清单（版本、统计、校验和）
/// └── data/
///     └── qing_notes.sqlite           SQLite 数据库快照
/// ```
///
/// 刻意**不包含** API Key：它在系统钥匙串里，不属于笔记数据，
/// 备份包通常会被放到网盘或聊天记录里，不能顺手把密钥也带出去。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 备份格式版本。将来清单字段变了就升这个号，导入时才能给出有意义的提示。
const kBackupFormatVersion = 1;

/// 清单中数据库条目的固定路径。
const kBackupDbEntryPath = 'data/qing_notes.sqlite';

/// 清单文件名。
const kBackupManifestPath = 'backup.json';

/// 备份包内的统计信息。
///
/// 导入前给用户看「这个包里有 42 条笔记、3 个笔记库」比看一堆时间戳有用得多，
/// 也是防止"选错了一个空备份把自己数据覆盖掉"的最后一道提示。
///
/// 早先这里还有 `cards` / `reviews` 两项（记忆卡片与复习流水）。
/// 功能删掉后一并移除：**新备份里没有这两张表了**，留着字段只会
/// 让每次备份都在 `SELECT COUNT(*) FROM cards` 上抛"表不存在"。
/// 老备份包里的这两个键会被 [fromJson] 自然忽略。
///
/// `tags` 同理：它是「用户手动标签」那张表（外加 `note_tags`）的行数，
/// 两张表都已在 schema v9 删除。**新备份不再统计标签**，
/// 老备份包里的 `tags` 键同样被 [fromJson] 忽略。
class BackupStats {
  const BackupStats({
    required this.notes,
    required this.notebooks,
  });

  final int notes;
  final int notebooks;

  static const empty = BackupStats(
    notes: 0,
    notebooks: 0,
  );

  Map<String, Object?> toJson() => {
        'notes': notes,
        'notebooks': notebooks,
      };

  static BackupStats fromJson(Object? raw) {
    if (raw is! Map) return empty;
    int read(String key) {
      final v = raw[key];
      if (v is int) return v;
      if (v is num) return v.toInt();
      return 0;
    }

    return BackupStats(
      notes: read('notes'),
      // 老备份包（v3 之前）里这个键叫 'folders'，而且那时语义是「目录」。
      // 同一个数字，换个名字读回来即可——不读它会让老包的摘要显示
      // "笔记库 0"，用户会以为备份是空的。
      notebooks:
          raw.containsKey('notebooks') ? read('notebooks') : read('folders'),
    );
  }

  /// 给用户看的一行摘要
  String get summary => '笔记 $notes · 笔记库 $notebooks';
}

/// 清单里的单个文件条目。保存 SHA-256 是为了导入时能发现"文件在传输中坏了"，
/// 而不是等到 App 打开一个半截的数据库才报奇怪的错。
class BackupFileEntry {
  const BackupFileEntry({
    required this.path,
    required this.size,
    required this.sha256,
  });

  final String path;
  final int size;
  final String sha256;

  Map<String, Object?> toJson() =>
      {'path': path, 'size': size, 'sha256': sha256};

  static BackupFileEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path'];
    final sha = raw['sha256'];
    if (path is! String || sha is! String) return null;
    final size = raw['size'];
    return BackupFileEntry(
      path: path,
      size: size is num ? size.toInt() : 0,
      sha256: sha,
    );
  }
}

/// 备份包清单。
class BackupManifest {
  const BackupManifest({
    required this.formatVersion,
    required this.appName,
    required this.appVersion,
    required this.schemaVersion,
    required this.createdAt,
    required this.sourcePlatform,
    required this.stats,
    required this.files,
    this.note,
  });

  final int formatVersion;
  final String appName;
  final String appVersion;
  final int schemaVersion;
  final DateTime createdAt;
  final String sourcePlatform;
  final BackupStats stats;
  final List<BackupFileEntry> files;

  /// 可选的说明，例如"从旧版本升级前的手动备份"
  final String? note;

  Map<String, Object?> toJson() => {
        'formatVersion': formatVersion,
        'appName': appName,
        'appVersion': appVersion,
        'schemaVersion': schemaVersion,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'sourcePlatform': sourcePlatform,
        'stats': stats.toJson(),
        'files': files.map((f) => f.toJson()).toList(),
        if (note != null) 'note': note,
      };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// 解析清单。字段缺失时用保守的默认值，但 [formatVersion] 必须存在——
  /// 没有版本号的"备份"无法判断兼容性，宁可拒绝也不要猜。
  static BackupManifest fromJson(Map<String, Object?> raw) {
    final version = raw['formatVersion'];
    if (version is! num) {
      throw const FormatException('备份清单缺少 formatVersion 字段');
    }
    final createdRaw = raw['createdAt'];
    DateTime created;
    try {
      created = DateTime.parse(createdRaw as String).toUtc();
    } catch (_) {
      created = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
    final filesRaw = raw['files'];
    final files = <BackupFileEntry>[];
    if (filesRaw is List) {
      for (final item in filesRaw) {
        final entry = BackupFileEntry.fromJson(item);
        if (entry != null) files.add(entry);
      }
    }
    final schemaRaw = raw['schemaVersion'];

    return BackupManifest(
      formatVersion: version.toInt(),
      appName: (raw['appName'] as String?) ?? 'LightNote',
      appVersion: (raw['appVersion'] as String?) ?? '未知',
      schemaVersion: schemaRaw is num ? schemaRaw.toInt() : 1,
      createdAt: created,
      sourcePlatform: (raw['sourcePlatform'] as String?) ?? '未知',
      stats: BackupStats.fromJson(raw['stats']),
      files: files,
      note: raw['note'] as String?,
    );
  }

  /// 导入前检查兼容性。返回 null 表示可以导入，否则返回给用户看的原因。
  String? compatibilityProblem(int currentSchemaVersion) {
    if (formatVersion > kBackupFormatVersion) {
      return '备份包格式版本为 $formatVersion，'
          '本 App 只支持到 $kBackupFormatVersion。请升级 App 后再导入。';
    }
    if (schemaVersion > currentSchemaVersion) {
      return '备份来自更新的 App（数据库版本 $schemaVersion > '
          '当前 $currentSchemaVersion），请先升级 App。';
    }
    return null;
  }

  String get createdAtLabel {
    final t = createdAt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }
}

/// 校验通过、等待用户确认的导入任务。
class ImportPreview {
  const ImportPreview({
    required this.archivePath,
    required this.manifest,
    required this.dbEntry,
  });

  final String archivePath;
  final BackupManifest manifest;

  /// 数据库文件在压缩包内的条目名
  final String dbEntry;

  String get headline {
    final existing = File(archivePath).existsSync();
    return existing ? p.basename(archivePath) : archivePath;
  }
}

/// 导入时如何处理当前已有数据。
enum ImportStrategy {
  /// 覆盖：当前数据库先备份到 `backups/` 再被替换。默认。
  replace,

  /// 并存：当前数据库保留在工作目录里，改名为 before-import-<时间>.sqlite
  keepBoth;

  String get label => switch (this) {
        ImportStrategy.replace => '覆盖当前数据（旧库自动备份）',
        ImportStrategy.keepBoth => '保留当前数据（旧库改名留在同目录）',
      };
}

/// 导出结果。
class ExportOutcome {
  const ExportOutcome({
    required this.primaryPath,
    required this.sizeBytes,
    required this.stats,
    this.autoCopyDir,
    this.autoCopyError,
  });

  /// 用户选择的位置（或私有目录里的自动备份）
  final String primaryPath;
  final int sizeBytes;
  final BackupStats stats;

  /// 另外自动留的一份（私有目录）。用户选了外部位置时才有值。
  final String? autoCopyDir;

  /// 自动留档失败的原因。失败了也要告诉用户，不能假装成功。
  final String? autoCopyError;

  String get sizeLabel {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / 1024 / 1024).toStringAsFixed(2)} MB';
  }
}

/// 导入结果（在启动阶段真正换库之后）。
class ImportOutcome {
  const ImportOutcome({
    required this.importedFrom,
    required this.stats,
    required this.strategy,
    this.previousBackupPath,
  });

  final String importedFrom;
  final BackupStats stats;
  final ImportStrategy strategy;

  /// `replace` 策略下旧数据库的落点；没备份则为 null
  final String? previousBackupPath;
}
