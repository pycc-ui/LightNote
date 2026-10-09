import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// 用 sqlite3 包直接读取 App 建出来的数据库，验证表结构与种子数据。
/// 本文件应放在 smart_notes 项目内执行（需要 package:sqlite3）。
void main(List<String> args) {
  final path = args.isNotEmpty
      ? args.first
      : r'C:\Users\43720\Downloads\py\appdata_test\轻笔记\qing_notes.sqlite';

  final file = File(path);
  stdout.writeln('数据库: $path');
  stdout.writeln('存在:   ${file.existsSync()}');
  if (!file.existsSync()) return;
  stdout.writeln('大小:   ${file.lengthSync()} 字节');
  stdout.writeln('');

  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    // 表清单
    final tables = db.select(
      "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
    );
    stdout.writeln('=== 表 (${tables.length}) ===');
    for (final r in tables) {
      stdout.writeln('  ${r['name']}');
    }

    // 索引
    final idx = db.select(
      "SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    );
    stdout.writeln('');
    stdout.writeln('=== 索引 (${idx.length}) ===');
    for (final r in idx) {
      stdout.writeln('  ${r['name']}');
    }

    // 各表行数
    stdout.writeln('');
    stdout.writeln('=== 行数 ===');
    for (final r in tables) {
      final name = r['name'] as String;
      if (name.startsWith('sqlite_')) continue;
      try {
        final c = db.select('SELECT COUNT(*) AS n FROM "$name"');
        stdout.writeln('  ${name.padRight(22)} ${c.first['n']}');
      } catch (e) {
        stdout.writeln('  ${name.padRight(22)} (读取失败: $e)');
      }
    }

    // 种子数据内容
    stdout.writeln('');
    stdout.writeln('=== notes 内容 ===');
    final notes = db.select(
      'SELECT title, is_inbox, word_count, folder_id FROM notes ORDER BY created_at',
    );
    for (final n in notes) {
      stdout.writeln('  标题=${n['title']}  isInbox=${n['is_inbox']}  '
          '字数=${n['word_count']}  folder=${n['folder_id']}');
    }

    stdout.writeln('');
    stdout.writeln('=== folders 内容 ===');
    for (final f in db.select('SELECT id, name FROM folders')) {
      stdout.writeln('  ${f['name']}  (${f['id']})');
    }

    // 外键是否开启过（PRAGMA 是连接级的，这里查不到，改查 schema）
    stdout.writeln('');
    stdout.writeln('=== 抽查 notes 表定义 ===');
    final ddl = db.select(
      "SELECT sql FROM sqlite_master WHERE type='table' AND name='notes'",
    );
    if (ddl.isNotEmpty) stdout.writeln('  ${ddl.first['sql']}');
  } finally {
    // sqlite3 3.x 起 dispose() 已废弃，改名 close()
    db.close();
  }
}
