import '../../../core/db/app_database.dart';
import '../../note/data/search_service.dart';
import 'ask_user.dart';

/// 把模型的 [AskRequest] 变成**真正给用户看的选项**。
///
/// 选项不能由模型给，有三个问题：库里 200 条笔记它**塞不进** prompt；
/// 它**记不住** id（会编）；而且那份清单**会变旧** —— 用户刚删掉的笔记
/// 还在选项里，点下去就是"找不到这条笔记"。
///
/// 所以模型只给**筛选条件**（`source: {kind: 'search', query: '会议'}`），
/// 选项由 App **现查现填**：永远和库一致、永远不超过几条、永远是最新的。
///
/// 模型直接给 `options` 也允许（不用 `source` 时），但那只是兜底 ——
/// 工具描述里明确劝它优先用 `source`。
class AskResolver {
  AskResolver(this._db) : _search = SearchService(_db);

  final AppDatabase _db;
  final SearchService _search;

  /// 解析出选项。
  ///
  /// 查不到任何东西时返回**空列表**（而不是抛错）：调用方会把它变成
  /// "没有可选项"的提示，模型据此改用 `text` 类型重新问。
  Future<List<AskOption>> resolve(AskRequest request) async {
    final source = request.source;
    if (source == null) {
      // 模型自己给的清单：截到上限，且**丢掉没有 id 的项**
      // （没有 id 的选项用户选了也没法回灌给模型）
      return request.options
          .where((o) => o.id.trim().isNotEmpty)
          .take(request.limit)
          .toList();
    }

    final take = request.limit;
    switch (source.kind) {
      case 'notebooks':
        final all = await _db.allNotebooks();
        return [
          for (final n in all.take(take))
            AskOption(id: n.id, label: n.name),
        ];

      case 'recentNotes':
        final briefs = await _db.noteBriefs(
          // `AskSource` 只带一个可选库 → 转成目录集合；不带就是不限（含轻笔记）
          notebookIds:
              source.notebookId == null ? null : [source.notebookId!],
          limit: take,
        );
        return [
          for (final b in briefs)
            AskOption(id: b.id, label: b.title.trim().isEmpty ? '无标题' : b.title),
        ];

      case 'search':
      default:
        // ⚠️ `search` 之外的未知 kind 也走搜索：模型可能编一个 kind，
        // 用它给的 query 搜一把比直接失败有用得多。
        final q = source.query.trim();
        if (q.isEmpty) {
          return [
            for (final b in await _db.noteBriefs(limit: take))
              AskOption(
                id: b.id,
                label: b.title.trim().isEmpty ? '无标题' : b.title,
              ),
          ];
        }
        final hits = await _search.search(
          q,
          notebookIds:
              source.notebookId == null ? null : [source.notebookId!],
          limit: take,
        );
        // 同一篇笔记命中多片时只留一条 —— 用户选的是"哪一篇"，
        // 不是"哪一片"；列五条同一篇的会让人以为有五篇。
        final seen = <String>{};
        final out = <AskOption>[];
        for (final h in hits) {
          if (!seen.add(h.noteId)) continue;
          out.add(AskOption(
            id: h.noteId,
            label: h.title.trim().isEmpty ? '无标题' : h.title,
            description: h.heading.isEmpty ? null : h.heading,
          ));
          if (out.length >= take) break;
        }
        return out;
    }
  }
}
