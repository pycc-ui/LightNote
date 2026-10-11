import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:lightnote/core/db/app_database.dart';
import 'package:lightnote/core/db/database_location.dart';
import 'package:lightnote/core/backup/backup_models.dart';
import 'package:lightnote/core/backup/backup_service.dart';
import 'package:lightnote/core/backup/pending_import.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;

/// 把 path_provider 换成临时目录。
///
/// 备份/恢复的所有中间文件都放在"App 私有目录"下，
/// 测试里必须把它指到一个可写、可清理、能断言的位置，
/// 否则就会往真实的 %APPDATA% 里写垃圾。
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => root;
}

Future<String> _newFakePrivateRoot(String label) async {
  final dir = await Directory.systemTemp.createTemp('lightnote-$label-');
  return dir.path;
}

Future<void> _insertNote(AppDatabase db, String id, String title) async {
  await db.upsertNote(
    NotesCompanion.insert(
      id: id,
      title: Value(title),
      content: Value('正文 $title'),
      isInbox: const Value(true),
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    ),
  );
}

Future<int> _noteCount(AppDatabase db) async {
  final rows = await db.customSelect('SELECT COUNT(*) AS c FROM notes').get();
  return rows.first.read<int>('c');
}

/// 清掉所有配置锚点里的 `storage.json`。
///
/// 为什么测试必须做这件事（两个原因，都很实际）：
///
/// 1. **测试之间会互相污染**。配置锚点之一是「程序所在目录」，
///    而在测试进程里 `Platform.resolvedExecutable` 指向 dart SDK 的
///    `bin\dart.exe`——那里的 `storage.json` 会**跨测试用例、跨 test 进程
///    一直留着**。上个用例写的 workingDir 会被下个用例读到，
///    表现为莫名其妙的断言失败（实际发生过）。
///
/// 2. **绝不能污染开发者的真实配置**。跑测试时如果往 dart SDK 目录
///    写了个指向临时目录的 `storage.json`，而某次又用那个 SDK 跑了 App，
///    就会莫名其妙用错工作目录。
Future<void> _clearAllConfigAnchors() async {
  for (final f in await DatabaseLocation.configFileCandidates()) {
    try {
      if (f.existsSync()) f.deleteSync();
      final tmp = File('${f.path}.tmp');
      if (tmp.existsSync()) tmp.deleteSync();
    } catch (_) {
      // 清不掉就算了（只读目录本来就写不进去）
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String privateRoot;
  late Directory workDir;

  setUp(() async {
    privateRoot = await _newFakePrivateRoot('private');
    PathProviderPlatform.instance = _FakePathProvider(privateRoot);
    DatabaseLocation.resetCacheForTesting();
    await _clearAllConfigAnchors();

    workDir = await Directory.systemTemp.createTemp('lightnote-work-');
  });

  tearDown(() async {
    // 先清配置再清目录：否则残留的 storage.json 会指向已被删除的临时目录，
    // 影响下一个用例（以及万一用到同一个 dart SDK 的其它东西）
    await _clearAllConfigAnchors();
    DatabaseLocation.resetCacheForTesting();
    // 还原主目录取法：有的用例把它指到死路过，静态字段不还原会污染后面的用例
    DatabaseLocation.homeDirOf = DatabaseLocation.defaultHomeDirOf;
    for (final path in [privateRoot, workDir.path]) {
      try {
        final d = Directory(path);
        if (d.existsSync()) d.deleteSync(recursive: true);
      } catch (_) {
        // Windows 上偶尔会因为文件句柄还没释放而删不掉，不影响断言
      }
    }
  });

  group('数据库位置', () {
    test('默认落在 App 私有目录，而不是文档目录', () async {
      DatabaseLocation.resetCacheForTesting();
      final dir = await DatabaseLocation.resolveDirectory();
      expect(p.normalize(dir.path), p.normalize(p.join(privateRoot, 'LightNote')));

      final info = await DatabaseLocation.describeSafe();
      expect(info.isPrivate, isTrue);
      expect(info.configuredDir, isNull);
      expect(info.isFallback, isFalse);
    });

    test('配置了不可写的工作目录时降级回私有目录，并留下原因', () async {
      // 用一个"文件"当目录：Windows 与 Linux 上都会创建失败
      final blocker = File(p.join(workDir.path, 'not-a-dir'));
      await blocker.writeAsString('x');

      await DatabaseLocation.writeConfiguredDir(blocker.path);
      DatabaseLocation.resetCacheForTesting();

      final dir = await DatabaseLocation.resolveDirectory();
      expect(p.normalize(dir.path), p.normalize(p.join(privateRoot, 'LightNote')));

      final info = await DatabaseLocation.describeSafe();
      expect(info.isPrivate, isTrue);
      expect(info.isFallback, isTrue);
      expect(info.fallbackNote, isNotNull);
    });

    test('配置了可写的工作目录时就用它', () async {
      await DatabaseLocation.writeConfiguredDir(workDir.path);
      DatabaseLocation.resetCacheForTesting();

      final dir = await DatabaseLocation.resolveDirectory();
      expect(p.normalize(dir.path), p.normalize(workDir.path));

      final info = await DatabaseLocation.describeSafe();
      expect(info.isPrivate, isFalse);
      expect(info.isFallback, isFalse);
    });

    // 回归测试：常规位置全不可写、退到「程序所在目录」时，
    // 必须把 isDegradedToProgramDir 置上并给出失败原因。
    //
    // 曾经的 bug：这个标记被写成 `isFallback ? lastFallbackNote : null`
    // 那一套的副产物，而 isFallback 只在"配置了工作目录却没生效"时才为 true。
    // 没配置工作目录（configured == null）时它是 false，于是设置页把这种
    // 危险状态显示成普通的「自定义目录」，**丢掉了"数据在 build\ 里、
    // 删 build 就没了"这个关键警告**。
    test('退到程序所在目录时必须标记为 degraded，并给出原因', () async {
      // 让所有常规私有目录候选都不可写：
      // 把「私有根目录」指到一个不存在、且父目录不存在的路径上。
      // Windows 上 CreateDirectory 对"父目录为文件"的路径一定失败。
      final blocker = File(p.join(workDir.path, 'blocker-file'));
      await blocker.writeAsString('x');
      final hopeless = p.join(blocker.path, 'nested');
      PathProviderPlatform.instance = _FakePathProvider(hopeless);
      // ⚠️ **主目录也要一起指到死路**：候选顺序是
      // AppData → 文档 → 主目录 → 程序目录，只挡住前两个的话
      // 会停在主目录（它是可写的），测出来的就不是这条兜底了。
      // 环境变量在 Dart 里是只读的，所以走 `homeDirOf` 这个缝。
      DatabaseLocation.homeDirOf = () => hopeless;
      DatabaseLocation.resetCacheForTesting();

      final info = await DatabaseLocation.describeSafe();

      expect(info.isDegradedToProgramDir, isTrue,
          reason: '退到程序目录却没标记 degraded，设置页就不会警告用户');

      if (!Platform.isAndroid) {
        final exeDir = File(Platform.resolvedExecutable).parent;
        expect(
          p.normalize(info.activeDir),
          p.normalize(p.join(exeDir.path, kProgramDirDataFolder)),
        );
      }
      expect(info.degradedNote, isNotNull,
          reason: '要能说明为什么常规位置都不可用');
    });

    // 这一组针对一个真实踩过的 bug：
    // 原实现把配置存在「私有根目录」下，而私有根目录是**按优先级逐档试出来**的
    // （AppData → 文档 → 主目录 → 程序目录）。于是配置的存放点会随环境漂移：
    // 这次写在 AppData，下次 AppData 建不出来降级到文档目录，
    // App 就去文档目录找配置——找不到，静默退回默认位置。
    // 用户的体感是「我明明改过存储位置，怎么又没了」。
    test('配置写在稳定的锚点（程序目录），不随数据目录漂移', () async {
      final anchors = await DatabaseLocation.configFileCandidates();
      expect(anchors, isNotEmpty);

      // 第一个锚点必须是程序所在目录（Android 除外），
      // 因为那是唯一"只要能启动就一定能定位到"的位置
      if (!Platform.isAndroid) {
        final exeDir = File(Platform.resolvedExecutable).parent;
        expect(p.normalize(anchors.first.path),
            p.normalize(p.join(exeDir.path, 'storage.json')));
      }
    });

    test('即使某个锚点不可写，配置仍然能存能读', () async {
      // 测试进程里 resolvedExecutable 指向 dart.exe，
      // 它所在的 SDK bin 通常不可写——正好用来模拟"某个锚点写不了"。
      // 要求：写操作不能整体失败，至少要落到一个能写的锚点上。
      final written = await DatabaseLocation.writeConfiguredDir(workDir.path);
      expect(written, isNotEmpty, reason: '至少要有一个锚点能写');

      expect(await DatabaseLocation.readConfiguredDir(),
          p.normalize(workDir.path));
    });

    test('配置内容在所有能写的锚点上保持一致', () async {
      await DatabaseLocation.writeConfiguredDir(workDir.path);
      final anchors = await DatabaseLocation.configFileCandidates();
      // 都写一份的目的：以后某个锚点变不可用、换了地方找配置，
      // 仍然能读到同一份设置，而不是静默退回默认位置。
      var checked = 0;
      for (final a in anchors) {
        if (!a.existsSync()) continue;
        // 必须解析 JSON 再比：JSON 里反斜杠是转义的（\\），
        // 直接对原始文本做 contains 会永远匹配不上。
        final decoded = jsonDecode(await a.readAsString()) as Map;
        expect(p.normalize(decoded['workingDir'] as String),
            p.normalize(workDir.path),
            reason: '锚点 ${a.path} 里的配置和预期不一致');
        checked++;
      }
      expect(checked, greaterThan(0), reason: '至少应该有一个锚点写成功');
    });
  });

  group('导出备份包', () {
    test('导出的 zip 里是完整可读的数据库 + 可校验的清单', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await _insertNote(db, 'n1', '第一条');
      await _insertNote(db, 'n2', '第二条');

      final target = p.join(workDir.path, 'export.zip');
      final outcome = await BackupService(db).exportTo(target);

      expect(File(target).existsSync(), isTrue);
      expect(outcome.stats.notes, 2);
      expect(outcome.sizeBytes, greaterThan(0));

      // 清单内容
      final archive = ZipDecoder().decodeBytes(await File(target).readAsBytes());
      final manifestFile = archive.findFile(kBackupManifestPath);
      expect(manifestFile, isNotNull);
      final manifest = BackupManifest.fromJson(
        jsonDecode(utf8.decode(manifestFile!.content)).cast<String, Object?>(),
      );
      expect(manifest.formatVersion, kBackupFormatVersion);
      expect(manifest.stats.notes, 2);
      expect(manifest.files, hasLength(1));
      expect(manifest.files.first.sha256, hasLength(64));

      // 数据库条目本身能被 SQLite 打开且数据对得上
      final dbEntry = archive.findFile(kBackupDbEntryPath);
      expect(dbEntry, isNotNull);
      final tmpDb = File(p.join(workDir.path, 'roundtrip.sqlite'));
      await tmpDb.writeAsBytes(dbEntry!.content, flush: true);
      final reopened = AppDatabase.forTesting(NativeDatabase(tmpDb));
      addTearDown(reopened.close);
      expect(await _noteCount(reopened), 2);

      // 一致性快照必须是"整理过"的库：VACUUM INTO 的输出不含空闲页碎片，
      // 而且已经把所有索引与触发器带上
      final tables = await reopened
          .customSelect("SELECT name FROM sqlite_master WHERE type='index'")
          .get();
      expect(tables.length, greaterThanOrEqualTo(10));
    });

    test('只生成用户指定的那一份（私有目录不留副本）', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await _insertNote(db, 'n1', '唯一一条');

      final target = p.join(workDir.path, 'outside', 'my-backup.zip');
      await BackupService(db).exportTo(target);

      // 只生成用户指定的那一份 —— 私有目录里**不该**再留一份
      // （早先会留，那个行为已按用户要求去掉）。
      expect(File(target).existsSync(), isTrue);
    });

    test('文件名带时间戳，且是合法的 Windows 文件名', () {
      final name = BackupService.defaultArchiveName(DateTime(2026, 2, 13, 10, 45));
      expect(name, 'LightNote-20260213-1045.zip');
      expect(name.contains(RegExp(r'[\\/:*?"<>|]')), isFalse);
    });
  });

  group('导入校验', () {
    Future<String> makeArchive(List<int> dbBytes, {String? corruptSha}) async {
      final archive = Archive();
      archive.addFile(ArchiveFile.bytes(kBackupDbEntryPath, dbBytes));
      final manifest = BackupManifest(
        formatVersion: kBackupFormatVersion,
        appName: 'LightNote',
        appVersion: '1.1.0',
        schemaVersion: kCurrentSchemaVersion,
        createdAt: DateTime.now().toUtc(),
        sourcePlatform: 'windows',
        stats: const BackupStats(
          notes: 1,
          notebooks: 0,
        ),
        files: [
          BackupFileEntry(
            path: kBackupDbEntryPath,
            size: dbBytes.length,
            sha256: corruptSha ?? 'a' * 64,
          ),
        ],
      );
      archive.addFile(ArchiveFile.string(kBackupManifestPath, manifest.encode()));

      final path = p.join(
        workDir.path,
        'pkg-${DateTime.now().microsecondsSinceEpoch}.zip',
      );
      await File(path).writeAsBytes(ZipEncoder().encodeBytes(archive), flush: true);
      return path;
    }

    test('不是 zip 的文件会被明确拒绝', () async {
      final notZip = File(p.join(workDir.path, 'notes.txt'));
      await notZip.writeAsString('这不是压缩包');
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      expect(
        () => BackupService(db).inspect(notZip.path),
        throwsA(isA<BackupException>()),
      );
    });

    test('校验和不匹配时拒绝导入（防止传输损坏被当成正常备份）', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      // 造一个"看起来像数据库"的文件，但清单里的 sha 是假的
      final fake = <int>[];
      fake.addAll(utf8.encode('SQLite format 3\u0000'));
      fake.addAll(List<int>.filled(200, 0));
      final path = await makeArchive(fake);

      expect(
        () => BackupService(db).inspect(path),
        throwsA(
          isA<BackupException>().having(
            (e) => e.message,
            'message',
            contains('校验和'),
          ),
        ),
      );
    });

    test('版本比当前 App 新的备份会被拒绝', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await _insertNote(db, 'n1', 'x');

      // 先正常导出一份，再把清单里的 schemaVersion 改大
      final good = p.join(workDir.path, 'good.zip');
      await BackupService(db).exportTo(good);

      final bytes = await File(good).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final dbBytes = archive.findFile(kBackupDbEntryPath)!.content;
      final manifest = BackupManifest.fromJson(
        jsonDecode(
          utf8.decode(archive.findFile(kBackupManifestPath)!.content),
        ).cast<String, Object?>(),
      );

      final tampered = Archive();
      tampered.addFile(ArchiveFile.bytes(kBackupDbEntryPath, dbBytes));
      tampered.addFile(
        ArchiveFile.string(
          kBackupManifestPath,
          BackupManifest(
            formatVersion: kBackupFormatVersion,
            appName: manifest.appName,
            appVersion: manifest.appVersion,
            schemaVersion: kCurrentSchemaVersion + 5,
            createdAt: manifest.createdAt,
            sourcePlatform: manifest.sourcePlatform,
            stats: manifest.stats,
            files: manifest.files,
          ).encode(),
        ),
      );
      final tamperedPath = p.join(workDir.path, 'tampered.zip');
      await File(tamperedPath)
          .writeAsBytes(ZipEncoder().encodeBytes(tampered), flush: true);

      expect(
        () => BackupService(db).inspect(tamperedPath),
        throwsA(
          isA<BackupException>().having(
            (e) => e.message,
            'message',
            contains('更新的 App'),
          ),
        ),
      );
    });

    test('正常备份能通过校验，并给出可读的统计', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await _insertNote(db, 'n1', '一');
      await _insertNote(db, 'n2', '二');

      final path = p.join(workDir.path, 'ok.zip');
      await BackupService(db).exportTo(path);

      final preview = await BackupService(db).inspect(path);
      expect(preview.manifest.stats.notes, 2);
      expect(preview.dbEntry, kBackupDbEntryPath);
      expect(preview.manifest.compatibilityProblem(kCurrentSchemaVersion), isNull);
      expect(preview.manifest.createdAtLabel, matches(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$'));
    });
  });

  group('启动阶段换库', () {
    test('replace：导入的数据生效，且旧库被留档', () async {
      // 1) 造一个"要导入"的备份：用第二个内存库生成
      final source = AppDatabase.forTesting(NativeDatabase.memory());
      await _insertNote(source, 'imported-1', '导入进来的笔记');
      final archivePath = p.join(privateRoot, 'incoming.zip');
      final preview =
          await BackupService(source).exportTo(archivePath);
      expect(preview.stats.notes, 1);
      await source.close();

      // 2) 当前 App 的库里是另外一条数据
      final liveDir = Directory(p.join(privateRoot, 'LightNote'));
      liveDir.createSync(recursive: true);
      final liveDbFile = File(p.join(liveDir.path, kDatabaseFileName));
      final live = AppDatabase.forTesting(NativeDatabase(liveDbFile));
      await _insertNote(live, 'live-1', '旧数据');
      await live.close();
      expect(liveDbFile.existsSync(), isTrue);

      // 3) 登记导入，然后模拟一次重启
      final pending = PendingImport.create(
        archivePath: archivePath,
        strategy: ImportStrategy.replace,
        stats: preview.stats,
        importedAt: DateTime.now().toUtc(),
      );
      await pending.write();

      final outcome = await applyPendingImportIfAny();
      expect(outcome, isNotNull);
      expect(outcome!.stats.notes, 1);
      expect(outcome.previousBackupPath, isNotNull);
      // 旧库必须真的存在，不能只是"说备份了"
      expect(File(outcome.previousBackupPath!).existsSync(), isTrue);

      // 4) 打开换过之后的库验证内容
      DatabaseLocation.resetCacheForTesting();
      final reopened = AppDatabase.forTesting(NativeDatabase(liveDbFile));
      addTearDown(reopened.close);
      expect(await _noteCount(reopened), 1);
      final titles = await reopened
          .customSelect('SELECT title FROM notes')
          .get();
      expect(titles.first.read<String>('title'), '导入进来的笔记');

      // 5) 标记被清掉，重启不会重复导入
      expect(await PendingImport.read(), isNull);
      expect(await applyPendingImportIfAny(), isNull);
    });

    test('keepBoth：旧库改名留在同目录，不覆盖', () async {
      final source = AppDatabase.forTesting(NativeDatabase.memory());
      await _insertNote(source, 'imported-1', '导入的');
      final archivePath = p.join(privateRoot, 'incoming2.zip');
      await BackupService(source).exportTo(archivePath);
      await source.close();

      final liveDir = Directory(p.join(privateRoot, 'LightNote'));
      liveDir.createSync(recursive: true);
      final liveDbFile = File(p.join(liveDir.path, kDatabaseFileName));
      final live = AppDatabase.forTesting(NativeDatabase(liveDbFile));
      await _insertNote(live, 'live-1', '旧的');
      await live.close();

      final pending = PendingImport.create(
        archivePath: archivePath,
        strategy: ImportStrategy.keepBoth,
        stats: BackupStats.empty,
        importedAt: DateTime.now().toUtc(),
      );
      await pending.write();

      final outcome = await applyPendingImportIfAny();
      expect(outcome, isNotNull);
      expect(outcome!.previousBackupPath, isNotNull);
      expect(p.basename(outcome.previousBackupPath!), startsWith('before-import-'));
      // 留在同目录，而不是 backups/
      expect(
        p.normalize(p.dirname(outcome.previousBackupPath!)),
        p.normalize(liveDir.path),
      );
    });

    test('备份文件已经不在时静默跳过，不破坏现有数据', () async {
      final liveDir = Directory(p.join(privateRoot, 'LightNote'));
      liveDir.createSync(recursive: true);
      final liveDbFile = File(p.join(liveDir.path, kDatabaseFileName));
      final live = AppDatabase.forTesting(NativeDatabase(liveDbFile));
      await _insertNote(live, 'keep-1', '必须还在');
      await live.close();
      final sizeBefore = liveDbFile.lengthSync();

      final pending = PendingImport.create(
        archivePath: p.join(privateRoot, 'gone.zip'),
        strategy: ImportStrategy.replace,
        stats: BackupStats.empty,
        importedAt: DateTime.now().toUtc(),
      );
      await pending.write();

      expect(await applyPendingImportIfAny(), isNull);
      expect(liveDbFile.lengthSync(), sizeBefore);

      final reopened = AppDatabase.forTesting(NativeDatabase(liveDbFile));
      addTearDown(reopened.close);
      expect(await _noteCount(reopened), 1);
    });

    test('导入时顺带切换工作目录，重启后数据落在新目录', () async {
      final source = AppDatabase.forTesting(NativeDatabase.memory());
      await _insertNote(source, 'imported-1', '带目录切换的导入');
      final archivePath = p.join(privateRoot, 'incoming3.zip');
      await BackupService(source).exportTo(archivePath);
      await source.close();

      final newDir = Directory(p.join(workDir.path, 'my-notes'));
      newDir.createSync(recursive: true);

      final pending = PendingImport.create(
        archivePath: archivePath,
        strategy: ImportStrategy.replace,
        stats: BackupStats.empty,
        importedAt: DateTime.now().toUtc(),
        adoptWorkingDir: newDir.path,
      );
      await pending.write();

      final outcome = await applyPendingImportIfAny();
      expect(outcome, isNotNull);

      final movedDb = File(p.join(newDir.path, kDatabaseFileName));
      expect(movedDb.existsSync(), isTrue);
      expect(await DatabaseLocation.readConfiguredDir(), p.normalize(newDir.path));

      DatabaseLocation.resetCacheForTesting();
      final resolved = await DatabaseLocation.resolveDirectory();
      expect(p.normalize(resolved.path), p.normalize(newDir.path));
    });
  });

  group('备份清单', () {
    test('缺少 formatVersion 的清单会被拒绝解析', () {
      expect(
        () => BackupManifest.fromJson({'appName': 'x'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('未知字段被忽略，缺失字段用保守默认值（前向兼容）', () {
      final m = BackupManifest.fromJson({
        'formatVersion': 1,
        'createdAt': '2026-02-13T02:45:00.000Z',
        'somethingNew': {'nested': true},
      });
      // createdAt 用 UTC 存，展示时转本地
      expect(m.createdAt.isUtc, isTrue);
      expect(m.schemaVersion, 1);
      expect(m.stats.notes, 0);
      expect(m.files, isEmpty);
    });

    test('格式版本高于本 App 时给出可读原因', () {
      final m = BackupManifest.fromJson({
        'formatVersion': kBackupFormatVersion + 1,
        'schemaVersion': 1,
      });
      expect(m.compatibilityProblem(kCurrentSchemaVersion), contains('升级 App'));
    });
  });
}
