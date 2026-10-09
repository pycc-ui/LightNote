import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/db/app_database.dart';
import '../core/util/text_utils.dart';

/// Markdown 导出与文本组装。
///
/// 设计取舍：不做 zip。导出一个 `.md` 文件有两个好处——
///   1. 不需要 archive 依赖；
///   2. 用户能直接在任何编辑器里看，也能整篇粘进别的笔记软件。
/// 单篇导出与整库导出共用同一套组装逻辑，避免两处格式不一致。
class MarkdownExportService {
  MarkdownExportService(this._db);

  final AppDatabase _db;

  /// 把一篇笔记渲染成 Markdown 文本（含元信息头）
  static String renderSingle(Note note, {List<String> tags = const []}) {
    final sb = StringBuffer();
    sb.writeln('# ${_titleOf(note)}');
    sb.writeln();
    sb.writeln('> 创建：${_fmt(note.createdAt)}　更新：${_fmt(note.updatedAt)}'
        '　字数：${note.wordCount}');
    if (tags.isNotEmpty) {
      sb.writeln('> 标签：${tags.map((t) => '#$t').join(' ')}');
    }
    sb.writeln();
    sb.writeln('---');
    sb.writeln();
    sb.writeln(note.content);
    return sb.toString();
  }

  /// 导出全部笔记为单个 Markdown 文件，返回文件路径。
  ///
  /// 结构：目录分组 → 目录内笔记 → 未归档笔记 → 轻笔记（收件箱）
  Future<String> exportAll() async {
    final folders = await _db.allFolders();
    final notes = await _db.allActiveNotes();

    final notesByFolder = <String?, List<Note>>{};
    for (final n in notes) {
      notesByFolder.putIfAbsent(n.folderId, () => []).add(n);
    }

    final sb = StringBuffer();
    sb.writeln('# LightNote 导出');
    sb.writeln();
    sb.writeln('> 导出时间：${_fmt(DateTime.now().toUtc())}');
    sb.writeln('> 笔记总数：${notes.length}　目录数：${folders.length}');
    sb.writeln();

    // 目录分组（按名称排序，保证导出结果稳定可 diff）
    final sortedFolders = [...folders]
      ..sort((a, b) => a.name.compareTo(b.name));

    for (final f in sortedFolders) {
      final list = notesByFolder[f.id];
      if (list == null || list.isEmpty) continue;
      sb.writeln('## 📁 ${f.name}');
      sb.writeln();
      for (final n in list) {
        sb.writeln('### ${_titleOf(n)}');
        sb.writeln();
        sb.writeln('> 更新：${_fmt(n.updatedAt)}　字数：${n.wordCount}');
        sb.writeln();
        sb.writeln(n.content);
        sb.writeln();
        sb.writeln('---');
        sb.writeln();
      }
    }

    // 已归档但没归目录的
    final orphan = notesByFolder[null] ?? const <Note>[];
    final archivedNoFolder =
        orphan.where((n) => !n.isInbox).toList(growable: false);
    if (archivedNoFolder.isNotEmpty) {
      sb.writeln('## 📄 未归目录');
      sb.writeln();
      for (final n in archivedNoFolder) {
        sb.writeln('### ${_titleOf(n)}');
        sb.writeln();
        sb.writeln(n.content);
        sb.writeln();
        sb.writeln('---');
        sb.writeln();
      }
    }

    // 轻笔记（收件箱）
    final inbox = orphan.where((n) => n.isInbox).toList(growable: false);
    if (inbox.isNotEmpty) {
      sb.writeln('## 📥 轻笔记（未整理）');
      sb.writeln();
      for (final n in inbox) {
        sb.writeln('### ${_titleOf(n)}');
        sb.writeln();
        sb.writeln(n.content);
        sb.writeln();
        sb.writeln('---');
        sb.writeln();
      }
    }

    final dir = await getApplicationDocumentsDirectory();
    final stamp = DateTime.now()
        .toIso8601String()
        .substring(0, 19)
        .replaceAll(':', '-');
    final file = File(p.join(dir.path, 'LightNote导出_$stamp.md'));
    await file.writeAsString(sb.toString(), flush: true);
    return file.path;
  }

  /// 组装「复制全文」的内容：标题 + 正文，便于粘到别处
  static String buildCopyText(Note note) {
    final title = note.title.trim();
    if (title.isEmpty) return note.content;
    return '$title\n\n${note.content}';
  }

  static String _titleOf(Note n) =>
      n.title.trim().isEmpty ? '无标题' : n.title.trim();

  static String _fmt(DateTime utc) {
    final l = utc.toLocal();
    return '${l.year}-${_pad2(l.month)}-${_pad2(l.day)} '
        '${_pad2(l.hour)}:${_pad2(l.minute)}';
  }

  /// 两位补零。名字用 _pad2 而不是 _2 —— 后者违反 lowerCamelCase 命名规范。
  static String _pad2(int v) => v.toString().padLeft(2, '0');
}

/// 搜索结果里高亮关键词时用的文本切片工具
class HighlightUtils {
  HighlightUtils._();

  /// 把文本按关键词切成若干片段，供 RichText 拼装高亮。
  /// 返回 (片段, 是否命中) 的列表。大小写不敏感。
  static List<(String, bool)> split(String text, String keyword) {
    if (keyword.trim().isEmpty) return [(text, false)];
    final lowerText = text.toLowerCase();
    final lowerKey = keyword.trim().toLowerCase();

    final out = <(String, bool)>[];
    var start = 0;
    while (true) {
      final idx = lowerText.indexOf(lowerKey, start);
      if (idx < 0) break;
      if (idx > start) out.add((text.substring(start, idx), false));
      out.add((text.substring(idx, idx + lowerKey.length), true));
      start = idx + lowerKey.length;
    }
    if (start < text.length) out.add((text.substring(start), false));
    return out.isEmpty ? [(text, false)] : out;
  }

  /// 从正文里截一段包含关键词的上下文，用于结果列表展示
  static String snippet(String content, String keyword, {int radius = 40}) {
    final plain = TextUtils.toPlainText(content).replaceAll('\n', ' ');
    if (keyword.trim().isEmpty) {
      return plain.length > radius * 2
          ? '${plain.substring(0, radius * 2)}…'
          : plain;
    }
    final idx = plain.toLowerCase().indexOf(keyword.trim().toLowerCase());
    if (idx < 0) {
      return plain.length > radius * 2
          ? '${plain.substring(0, radius * 2)}…'
          : plain;
    }
    final from = (idx - radius).clamp(0, plain.length);
    final to = (idx + keyword.length + radius).clamp(0, plain.length);
    final prefix = from > 0 ? '…' : '';
    final suffix = to < plain.length ? '…' : '';
    return '$prefix${plain.substring(from, to)}$suffix';
  }
}
