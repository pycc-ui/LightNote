import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:smart_notes/core/db/app_database.dart';
import 'package:smart_notes/core/db/database_location.dart';
import 'package:smart_notes/services/backup/backup_models.dart';
import 'package:smart_notes/services/backup/backup_service.dart';
import 'package:smart_notes/services/backup/pending_import.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String privateRoot;
  late Directory workDir;

  setUp(() async {
    privateRoot = await _newFakePrivateRoot('private');
    PathProviderPlatform.instance = _FakePathProvider(privateRoot);
    DatabaseLocation.resetCacheForTesting();

    workDir = await Directory.systemTemp.createTemp('lightnote-work-');
  });

  tearDown(() async {
    DatabaseLocation.resetCacheForTesting();
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

      final info = await DatabaseLocation.describe();
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

      final info = await DatabaseLocation.describe();
      expect(info.isPrivate, isTrue);
      expect(info.isFallback, isTrue);
      expect(info.fallbackNote, isNotNull);
    });

    test('配置了可写的工作目录时就用它', () async {
      await DatabaseLocation.writeConfiguredDir(workDir.path);
      DatabaseLocation.resetCacheForTesting();

      final dir = await DatabaseLocation.resolveDirectory();
      expect(p.normalize(dir.path), p.normalize(workDir.path));

      final info = await DatabaseLocation.describe();
      expect(info.isPrivate, isFalse);
      expect(info.isFallback, isFalse);
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

    test('会自动在私有目录留一份（用户选的位置丢了也不至于没备份）', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await _insertNote(db, 'n1', '唯一一条');

      final target = p.join(workDir.path, 'outside', 'my-backup.zip');
      final outcome = await BackupService(db).exportTo(target);

      expect(File(target).existsSync(), isTrue);
      expect(outcome.autoCopyDir, isNotNull);
      final auto = File(p.join(outcome.autoCopyDir!, 'my-backup.zip'));
      expect(auto.existsSync(), isTrue);

      final listed = await BackupService(db).listAutoBackups();
      expect(listed.map((f) => p.basename(f.path)), contains('my-backup.zip'));
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
          folders: 0,
          tags: 0,
          cards: 0,
          reviews: 0,
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
      await BackupService(db).exportTo(good, alsoKeepPrivateCopy: false);

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
      await BackupService(db).exportTo(path, alsoKeepPrivateCopy: false);

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
          await BackupService(source).exportTo(archivePath, alsoKeepPrivateCopy: false);
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
      await BackupService(source).exportTo(archivePath, alsoKeepPrivateCopy: false);
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
      await BackupService(source).exportTo(archivePath, alsoKeepPrivateCopy: false);
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
