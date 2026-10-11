import 'dart:async';
import 'dart:math';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import '../../../core/db/app_database.dart';
import '../../../core/db/models.dart';
import '../../../core/util/ai_limits.dart';
import '../../ai/domain/ai_repository.dart';
import '../domain/feed_window.dart';
import '../domain/note_chunk.dart';
import 'note_ai_asset_repository.dart';
import 'note_chunk_repository.dart';

/// 一屏显示几张卡片。
///
/// **这个不动**：屏幕上一屏就是 3 张。
const kFeedBatchSize = 3;

/// 后台常备几张。低于这个数就在取完一屏后补。
///
/// 取 12 = **4 屏余量**。用户连刷 3~4 次都不用等生成
/// （生成一批要 5~10 秒，而连刷几次只要几秒）。
const kFeedPoolTarget = 12;

/// 一次请求生成几张。
///
/// 比 [kFeedBatchSize] 大得多：一次请求拿 9 张，比分三次各拿 3 张
/// 省两次往返，token 成本几乎一样（素材 prompt 只发一次）。
///
/// **不能无限大**：一条正文 400~800 字，9 条的 JSON 已经接近 8192 token
/// 的输出上限，再多会被截断（截断后 JSON 解析失败，整批白烧）。
/// 配套见 `AiRepository.generateFeedNotes` 的 `maxTokens`。
const kFeedGenerateCount = 9;

/// 每次启动给**下次**预留几张（存进 `feed_reserve` 表）。
///
/// 取 6 = **2 屏**：下次进入先把这 6 张放进内存池，前 3 张当屏秒出，
/// 剩下 3 张立刻够用户下拉一次（不用等生成）。
const kFeedReserveSize = 6;

/// **来源冷却窗口**：最近这么多张卡片里，同一篇笔记最多出现 1 次。
///
/// 取 12（比一屏 3 张大、也比一次生成 9 张大）：连续两批卡片的素材
/// 不会重叠，用户不会连着看到同一篇笔记的内容。
///
/// 只记**笔记**级别、只记内存：不记"用过哪一块"
/// （块重复概率本来就低，见 `gatherSources` 的说明），
/// 也不落库（进程重启就重置，代价为零）。
const kRecentNoteKeep = 12;

/// **切片记忆窗口**：最近这么多块不重复取。
///
/// 设计文档原本说"不记录用过的块"，理由是"一篇 10 块，连抽两次命中同一块
/// 只有 10%"。**那个前提现在不成立**：一次要取 9 份素材，
/// 一篇 10 块的笔记等于每批用掉 90%，两批之间必然大量重叠。
///
/// 取 60 ≈ 6~7 批的量：笔记多的时候这层记忆自然不起作用（每篇都还有没用过的块），
/// 只在笔记少、块被反复取的时候才兜住。
///
/// 只记内存、只记 hash（不存块内容，省内存）：hash 撞了最多是少用一个块，无害。
const kRecentChunkKeep = 60;

/// **标题记忆窗口**：最近这么多张卡片的标题算「已经生成过」。
///
/// 取 40 ≈ 4~5 批：够覆盖池子（最多 24 张）+ 预留（6 张）+ 刚看过的，
/// 又不至于让 prompt 里那串「别重复」清单太长。
const kRecentTitleKeep = 40;

// ---- app_kv 表的 key ----
//
// 来源的存法：**只存「用户不要什么」，不存「用户要什么」**。
//   · `feed_source_excluded` 不存在或为空 → 不排除任何 → **全选**
//   · `feed_include_unfiled` 不存在        → **包含「我的轻笔记」**
//
// 于是"默认全选 + 我的轻笔记"**不需要写任何东西**；而**新建的笔记库不在排除集里，
// 自然就被勾选** —— 见 [FeedRepository.resolveSource]。
//
// ## 历史（为什么不是"包含集"）
//
// 早先用 `feed_source_notebooks`（**包含集**）+ `feed_source_initialized`
// + `feed_source_customized` 三个 key，靠"存一份快照 + 把缺的库补回来"实现同一件事。
// 那套有两个毛病：
//
//   ① 一个 id"不在集合里"**分不清**"从没见过"和"用户取消的"，
//      所以必须再加 `customized` 标记来区分"用户改过没有"；
//   ② 补新库的那段"对账"只在页面 `initState` 里跑一次，而三个 tab 用
//      `IndexedStack` 保活、切标签不重建页面 —— 于是**用户在笔记库页新建的库
//      不会进来源**，要重启 App 才对。
//
// 改成排除集之后：①无歧义（不在排除集 = 包含）、②不需要对账（每次现算）。
// 三个旧 key 全部停用；**新 key 必须换名字**，否则老的"包含集"会被当成"排除集"读，
// 语义正好反过来（把用户所有库都排除掉）。
const _kSourceExcluded = 'feed_source_excluded';
const _kIncludeUnfiled = 'feed_include_unfiled';

/// 卡片流的内容来源：从哪些笔记库取素材。
class FeedSource {
  const FeedSource({
    required this.notebookIds,
    required this.includeUnfiled,
  });

  final List<String> notebookIds;
  final bool includeUnfiled;

  static const empty = FeedSource(notebookIds: [], includeUnfiled: false);

  /// 一个来源都没选 -> 页面显示引导，而不是空列表
  bool get isEmpty => notebookIds.isEmpty && !includeUnfiled;

  FeedSource copyWith({List<String>? notebookIds, bool? includeUnfiled}) {
    return FeedSource(
      notebookIds: notebookIds ?? this.notebookIds,
      includeUnfiled: includeUnfiled ?? this.includeUnfiled,
    );
  }
}

/// 卡片流仓储。
///
/// ## 内容从哪来
///
/// 卡片流里的「轻笔记」是 **AI 从素材里长出来的新内容**，
/// 不是已有笔记的视图。所以这里不再"抽取已有笔记"，
/// 而是"取素材 -> 调 AI 生成 -> 放进内存池"。
///
/// ## 为什么不落库
///
/// 产品决定：生成结果**只放内存**，用户点「加入我的轻笔记」时才写成
/// 真正的笔记。好处是不用新表、不扰动数据；代价是杀掉进程后
/// 没被收下的那批就没了（下次会重新生成，内容不同）。
///
/// ## 池子的用法
///
/// 维护一个 [kFeedPoolTarget] 张的缓冲池，页面一次取 [kFeedBatchSize] 张。
/// 池子见底就在后台补——所以"下拉刷新"通常是**瞬间**出内容，不用等 AI；
/// 只有池子空且恰好没在生成时才会转圈。
///
/// 早先这里还有一整套"笔记消费状态"（`note_feed_state` 表：到期时间、
/// 间隔天数、难度因子、收藏）。那套是为"复习已有笔记"设计的，
/// 现在卡片是 AI 新生成的、不复用同一条内容，所以不再需要。
/// 那张表（连同 `idx_feed_due` / `idx_feed_starred` 两条索引）**已在 v8 删除**。
class FeedRepository {
  FeedRepository(this._db, this._ai, {NoteAiAssetRepository? assets})
      : _assets = assets ?? NoteAiAssetRepository(_db),
        _chunks = NoteChunkRepository(_db);

  final AppDatabase _db;
  final AiRepository _ai;

  /// 笔记的 AI 摘要。**持久化资产**，不是临时缓存——
  /// 每篇笔记生成一次后长期复用，也是卡片流的素材来源。
  final NoteAiAssetRepository _assets;

  /// 笔记切片：素材取自片内的 400 字窗口。
  ///
  /// 懒回填与自愈都在它那里 —— 老库升上来的笔记第一次被卡片流碰到时
  /// 才会现切一遍，调用方不用管。
  final NoteChunkRepository _chunks;

  // ---- 内存池 ----
  final List<FeedDraft> _pool = [];
  Future<void>? _inflight;

  /// 选切片用的随机数。用时间种子，让连续抽到同一篇笔记时选块也会变。
  final _random = Random();

  /// **来源冷却**：最近用过的笔记 id，最新的在前。
  ///
  /// 目的：同一篇笔记不在最近 [kRecentNoteKeep] 张卡片里重复出现。
  ///
  /// 注意它**只记笔记级别、只记内存**：
  /// 不记"用过哪一块"（块重复概率本来就低，见 [gatherSources] 的说明），
  /// 也不落库（进程重启就重置，代价为零）。
  final List<String> _recentNoteIds = [];

  /// **切片记忆**：最近用过的切片（存 `noteId:idx`，最新的在前）。
  ///
  /// ⚠️ 键是 `noteId:idx` 而**不是片正文的 hash**：素材改成"片内的 400 字
  /// 窗口"之后，同一片每次取出的文字都不一样，按 text hash 去重等于完全失效。
  ///
  /// 这一份只是**一次会话内的快速过滤**；真正的保证是落库的
  /// `note_chunks.last_used_at`（重启后仍然生效，见《数据库设计》的
  /// 「note_chunks（笔记切片）」一节）。
  final List<String> _recentChunks = [];

  /// **已生成过的卡片标题**（最新的在前），见 [kRecentTitleKeep]。
  ///
  /// 两个用途：
  ///   · 列进 prompt，让模型主动避开（笔记少时切片会反复取到）
  ///   · 生成后拿它过滤掉撞车的卡片
  final List<String> _recentTitles = [];

  /// 池子里还有几张
  int get poolSize => _pool.length;

  /// 正在生成中
  bool get isGenerating => _inflight != null;

  /// 记下这次用过的笔记 id（最新的排在最前）。
  void _rememberUsed(Iterable<String> ids) {
    _recentNoteIds.insertAll(0, ids);
    if (_recentNoteIds.length > kRecentNoteKeep) {
      _recentNoteIds.removeRange(kRecentNoteKeep, _recentNoteIds.length);
    }
  }

  // ==========================================================================
  // 来源配置
  // ==========================================================================

  /// 解析「有效来源」：**当前全部笔记库 − 用户明确排除的**。
  ///
  /// 这是来源的**唯一入口**，每次现算、**不存快照**。
  /// 所以"新建的笔记库自动加入"是**构造性成立**的 —— 新库不可能出现在排除集里，
  /// 也就不需要任何"对账"逻辑，更不会因为谁忘了刷新而失效。
  Future<FeedSource> resolveSource() async {
    final all = await _db.allNotebooks();
    final excluded = await _readExcludedIds();
    final includeUnfiled = await _readIncludeUnfiled();
    return FeedSource(
      notebookIds: [
        for (final n in all)
          if (!excluded.contains(n.id)) n.id,
      ],
      includeUnfiled: includeUnfiled,
    );
  }

  /// 用户保存来源时写：**把"没勾上的"存成排除集**（按当前全部库重算）。
  ///
  /// 存"用户不要什么"而不是"用户要什么"是这套设计的枢纽：
  /// 将来新建的库不在这个集合里 → **自动被勾选**。
  ///
  /// 顺带好处：因为每次都按当前全部库重算，**已删除的笔记库 id 不会残留**。
  Future<void> writeSource(FeedSource source) async {
    final all = await _db.allNotebooks();
    final keep = source.notebookIds.toSet();
    final excluded = [
      for (final n in all)
        if (!keep.contains(n.id)) n.id,
    ];
    await _db.writeSetting(_kSourceExcluded, jsonEncode(excluded));
    await _db.writeSetting(_kIncludeUnfiled, source.includeUnfiled.toString());
  }

  /// 「恢复默认」：清掉两个 key → 回到"全选所有笔记库 + 包含我的轻笔记"。
  ///
  /// ⚠️ 别用 `writeSource(全部)` 来表达这件事。那样虽然结果暂时相同，但它写下的是
  /// "用户表过态：全都要"，而清 key 表达的是"用户从没表过态" —— 后者才是默认态。
  Future<void> resetSource() async {
    await _db.deleteSetting(_kSourceExcluded);
    await _db.deleteSetting(_kIncludeUnfiled);
  }

  /// 用户**明确取消勾选**的笔记库 id。空 = 没排除任何。
  ///
  /// 损坏时返回空集而不是抛错：**"当成全选"比"当成全排除"安全得多** ——
  /// 后者会让卡片流突然全空，用户完全不知道发生了什么。
  Future<Set<String>> _readExcludedIds() async {
    final raw = await _db.readSetting(_kSourceExcluded);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.whereType<String>().toSet();
    } catch (_) {
      // 走下面的兜底
    }
    return const {};
  }

  /// 是否包含「我的轻笔记」。**缺省 true** —— 对应"默认全选 + 我的轻笔记"。
  Future<bool> _readIncludeUnfiled() async =>
      (await _db.readSetting(_kIncludeUnfiled)) != 'false';

  // ==========================================================================
  // 素材
  // ==========================================================================

  /// 按来源配置取素材：**每条笔记给一份「摘要 + 一块随机切片」**。
  ///
  /// ## 为什么是"摘要 + 切片"
  ///
  /// | 内容 | 作用 | 性质 |
  /// |---|---|---|
  /// | 摘要 | 整体背景 | 概括，AI 生成，**存库复用** |
  /// | 切片 | 具体内容 | 原文片段，**不失真，现切不存** |
  ///
  /// 只发摘要是试过的，结果是**卡片大而空**——摘要天生概括，
  /// AI 拿到概括只能再概括一遍。切片是原文，里面才有具体数字、
  /// 具体说法、具体例子可以参考。
  ///
  /// ## 为什么不存切片、不记录用过的块
  ///
  /// 切片完全由正文决定，存下来只会带来"与正文不一致 / 改了要重切 /
  /// 建表迁移处理失效"一整条链路，而切一遍是毫秒级。
  ///
  /// 用过的块也不记：一篇 10 块，连抽两次命中同一块只有 10%；
  /// 而且同一块每次生成的卡片本来就不同。**用一点随机性换零状态管理。**
  ///
  /// ## 摘要生成失败会退回正文截断
  ///
  /// 见 [_ensureSummary]：保证不会因为一次摘要失败就生成不出卡片。
  Future<List<FeedMaterial>> gatherSources(
    FeedSource source, {
    int limit = 8,
  }) async {
    // 多取一些候选：来源冷却会筛掉最近用过的，得有备选可挑。
    final notes = await _db.notesForFeed(
      notebookIds: source.notebookIds,
      includeUnfiled: source.includeUnfiled,
      limit: limit * 2,
    );
    final usable =
        notes.where((n) => n.content.trim().isNotEmpty).toList(growable: false);
    if (usable.isEmpty) return const []; // 正文都为空 → 没素材

    // ---- 来源冷却：优先用最近**没出现过**的笔记 ----
    //
    // 只做笔记级别的冷却（同一篇笔记不在最近 N 张卡片里重复出现），
    // 不做块级别的记录——见上面"不记录用过的块"。
    final fresh = usable.where((n) => !_recentNoteIds.contains(n.id)).toList();
    final chosen = fresh.length >= limit
        ? fresh.take(limit).toList()
        : [
            ...fresh,
            ...usable.where((n) => _recentNoteIds.contains(n.id)),
          ].take(limit).toList();
    if (chosen.isEmpty) return const [];

    // 记下这次用了哪些（**只记真正发给 AI 的**）
    _rememberUsed(chosen.map((n) => n.id));

    // 一次查完已有的新鲜摘要，避免逐条查库
    final cached = await _assets.freshSummaries(chosen.map((n) => n.id));

    // ---- 先给每篇笔记取好片，丢掉取不出片的 ----
    //
    // 片统一从仓储来（**懒回填 + 自愈**都在它那里）：老库升上来的笔记
    // 第一次被卡片流碰到时才会现切一遍，这里不用管。
    final chunksOf = <String, List<NoteChunk>>{};
    final noteOf = <String, Note>{};
    for (final n in chosen) {
      final cs = await _chunks.chunksFor(n.id, n.content);
      if (cs.isEmpty) continue; // 正文为空 → 跳过这篇笔记
      chunksOf[n.id] = cs;
      noteOf[n.id] = n;
    }
    if (chunksOf.isEmpty) return const [];

    // 只给真正会用到的笔记生成摘要
    final summaries = <String, String>{};
    for (final id in chunksOf.keys) {
      summaries[id] = cached[id] ?? await _ensureSummary(noteOf[id]!);
    }

    // ---- 轮转取素材，凑够 [limit] 份 ----
    //
    // ⚠️ **这里不能让"素材数 = 笔记数"。**
    //
    // 曾经写成"一篇笔记一份素材"，于是库里只有 3 条笔记时**只能生成 3 张卡**：
    // 内存池永远补不满，用户等了一次又一次。这是实测被用户抓到的回归。
    //
    // 切片设计的本来好处就是"同一篇笔记能出很多块"，正好用来解耦：
    // 笔记少就**从同一篇笔记取不同的片**，每片说的是不同的事，
    // 出来的卡片自然不重复——比"让模型对着同一段换着说法写"质量更高。
    //
    // 只有当**所有笔记的片数加起来都不够**时（比如 3 条短笔记各 1 片），
    // 才会少于 [limit]。那时由提示词让模型"从不同角度补足张数"。
    //
    // ---- 排序：**最近没用过的片排前面**（依据是落库的 last_used_at）----
    //
    // 持久化是关键：早先只在内存里记（`_recentChunks`），**重启即失效**，
    // 于是每次冷启动都会重新抽到同一批片，卡片大段重复。
    final order = chunksOf.keys.toList()..shuffle(_random);
    final ordered = <String, List<NoteChunk>>{};
    for (final id in order) {
      final cs = List<NoteChunk>.from(chunksOf[id]!)
        ..sort((a, b) {
          final au = a.lastUsedAt;
          final bu = b.lastUsedAt;
          if (au == null && bu == null) return 0; // 都没用过 → 保持打乱后的顺序
          if (au == null) return -1; // 没用过的优先
          if (bu == null) return 1;
          return au.compareTo(bu); // 越久没用过越优先
        });
      // 会话内那层快速过滤（真正的保证是上面那次按 last_used_at 排序）
      final unused = <NoteChunk>[];
      final used = <NoteChunk>[];
      for (final c in cs) {
        (_recentChunks.contains(c.keyOf(id)) ? used : unused).add(c);
      }
      ordered[id] = [...unused, ...used]; // 没用过的排前面
    }

    final now = DateTime.now().toUtc();
    final cursor = {for (final id in order) id: 0};
    final out = <FeedMaterial>[];
    var progressed = true;

    while (out.length < limit && progressed) {
      progressed = false;
      for (final id in order) {
        if (out.length >= limit) break;
        final cs = ordered[id]!;
        final i = cursor[id]!;
        if (i >= cs.length) continue; // 这篇的片取完了
        cursor[id] = i + 1;
        progressed = true;

        final chunk = cs[i];
        // 从片里开一个 400 字的窗口（片 ≤400 就是整片）
        final starts = FeedWindow.starts(chunk.charCount);
        // 轮换位存的是"下次该用哪个起点"；候选变了（正文改过）就回到第一个
        final start = starts.contains(chunk.nextWindowStart)
            ? chunk.nextWindowStart
            : starts.first;
        final text = FeedWindow.textOf(noteOf[id]!.content, chunk, start);
        if (text.trim().isEmpty) continue;

        _rememberChunk(chunk.keyOf(id));
        // 记下"这片用过了" + 推进窗口轮换位。**落库**，重启后仍然生效。
        await _db.markChunkUsed(
          id,
          chunk.index,
          at: now,
          nextWindowStart: FeedWindow.nextStart(starts, start),
        );

        out.add(FeedMaterial(
          title: noteOf[id]!.title,
          summary: summaries[id] ?? '',
          chunk: text,
          chunkKey: chunk.keyOf(id),
        ));
      }
    }
    return out;
  }

  /// 记下这个切片刚被用过（最新的排最前）。
  ///
  /// 键是 `noteId:idx`，不是片正文的 hash —— 素材现在是片内的 400 字窗口，
  /// 同一片每次取出的文字都不同，按 text hash 记等于没记。
  void _rememberChunk(String key) {
    _recentChunks.insert(0, key);
    if (_recentChunks.length > kRecentChunkKeep) {
      _recentChunks.removeRange(kRecentChunkKeep, _recentChunks.length);
    }
  }

  /// 确保某篇笔记有新鲜摘要，返回可用作素材的文本。
  ///
  /// 生成失败或产出为空时**退回正文截断**——这是刻意的降级：
  /// 摘要只是省钱的优化，不该成为"生成不出卡片"的单点故障。
  Future<String> _ensureSummary(Note note) async {
    try {
      final summary = await _ai.summarizeNote(
        title: note.title,
        content: note.content,
      );
      await _assets.putSummary(note.id, summary);

      if (summary.isNotEmpty) return summary;
    } catch (_) {
      // 落到下面退回正文
    }
    // 降级：正文截断到摘要上限，形状与摘要一致
    return safeTruncate(note.content.trim(), AiLimits.summaryHardMax);
  }

  // ==========================================================================
  // 生成与取用
  // ==========================================================================

  /// 取一屏卡片，并保证后台继续补足池子。
  ///
  /// ## 生成**不是**"池子空了才启动"
  ///
  /// 流程是：
  ///   1. 池子空 → `await refill`（**唯一会等的地方**，因为不等就没卡片可给）
  ///   2. 从池子**头部**取 [kFeedBatchSize] 张
  ///   3. **不管池子还剩多少，都 `unawaited(refill)`** ← 提前启动下一批
  ///
  /// 所以第 3 步在每次取卡片后都会跑，池子是在"还有货"的时候就开始补的。
  /// 真正决定"用户能连刷几次不用等"的是 [kFeedPoolTarget]：
  /// 常备 12 张 = 4 屏，用户连刷 4~5 次才会碰到池子空。
  ///
  /// 第 1 步的等待无法完全消除——池子真空时只能等，否则就要给用户
  /// 看空白（比等更糟）。所以只能靠把池子备厚来避免走到那一步。
  ///
  /// ## 并发安全
  ///
  /// 第 1 步和第 3 步都走 [refill]，它内部用 `_inflight` 共用同一个
  /// future——**同一时刻只会有一批在生成**，不会重复烧 token。
  /// [override] **仅供测试**：显式指定来源。
  ///
  /// **生产代码不要传。** 不传时内部走 [resolveSource] 现算 ——
  /// 这样任何触发路径（切 tab、下拉刷新、后台补池）都**不可能用到过期的来源**，
  /// 也就不会再出现"新建的笔记库要重启才生效"。
  Future<List<FeedDraft>> takeBatch([FeedSource? override]) async {
    final source = override ?? await resolveSource();
    if (_pool.isEmpty) {
      await refill(source);
    }
    final take = _pool.length < kFeedBatchSize ? _pool.length : kFeedBatchSize;
    final batch = _pool.take(take).toList(growable: false);
    _pool.removeRange(0, take);

    // 提前补：不 await，也不看池子是否为空
    _refillInBackground(source);
    return batch;
  }

  /// 把池子补到 [kFeedPoolTarget]。
  ///
  /// 并发调用共用同一个 future（[_inflight]），不会重复烧 token。
  ///
  /// [override] **仅供测试**，见 [takeBatch]。
  Future<void> refill([FeedSource? override]) async {
    final running = _inflight;
    if (running != null) return running;
    final source = override ?? await resolveSource();
    if (source.isEmpty) return;
    if (_pool.length >= kFeedPoolTarget) return;

    final future = _doRefill(source);
    _inflight = future;
    return future.whenComplete(() {
      if (identical(_inflight, future)) _inflight = null;
    });
  }

  Future<void> _doRefill(FeedSource source) async {
    // 素材尽量凑够 kFeedGenerateCount 份（笔记少就从同一篇多取几块）
    final materials = await gatherSources(
      source,
      limit: kFeedGenerateCount,
    );
    if (materials.isEmpty) return; // 没素材，调用方据此显示空状态

    // **张数单独说**：素材凑不够时靠提示词让模型从不同角度补足，
    // 保证这次生成还是 kFeedGenerateCount 张，池子能一次补满。
    // 同时把"已有的标题"告诉模型，让它避开——笔记少时切片会反复取到，
    // 只靠换块治不了重复。
    final drafts = await _ai.generateFeedNotes(
      materials,
      count: kFeedGenerateCount,
      avoidTitles: existingTitles(),
    );
    _pool.addAll(dropSimilarDrafts(drafts, against: _recentTitles));
    _rememberTitles(_pool.map((d) => d.title));
    // 池子不该无限长：只保留最新的若干张
    while (_pool.length > kFeedPoolTarget * 2) {
      _pool.removeAt(0);
    }
  }

  // ==========================================================================
  // 去重：库里笔记少的时候，切片会被反复取到，生成的卡片容易"换个说法同一件事"
  //
  // 三道防线（从便宜到贵）：
  //   1. 取块时优先跳过最近用过的块（[_recentChunks]）
  //   2. 把已有标题列进 prompt，让模型**主动避开**（[existingTitles]）
  //   3. 生成后把和已有标题太像的**直接丢掉**（[dropSimilarDrafts]）
  //
  // 第 3 道是兜底：提示词只是"建议"，模型不保证听。丢掉比让用户看到两张
  // 几乎一样的卡片好。
  // ==========================================================================

  /// 池子里 + 预留里已经有的卡片标题（给提示词当"别重复"清单）。
  List<String> existingTitles() {
    final out = <String>[..._pool.map((d) => d.title), ..._recentTitles];
    return out.where((t) => t.trim().isNotEmpty).toList(growable: false);
  }

  /// 记下这批卡片的标题（最新的在前）。
  void _rememberTitles(Iterable<String> titles) {
    _recentTitles.insertAll(0, titles);
    if (_recentTitles.length > kRecentTitleKeep) {
      _recentTitles.removeRange(kRecentTitleKeep, _recentTitles.length);
    }
  }

  /// 丢掉与 [against] 里任何标题**太像**的草稿，**以及同一批里自己撞车的**。
  ///
  /// 注意**不要**在 `against` 为空时提前返回：同一批里模型完全可能给出
  /// 两个同标题的卡片，那也要只留一张。
  static List<FeedDraft> dropSimilarDrafts(
    List<FeedDraft> drafts, {
    required List<String> against,
  }) {
    final seen = against.map(_fingerprint).where((s) => s.isNotEmpty).toSet();
    final out = <FeedDraft>[];
    for (final d in drafts) {
      final f = _fingerprint(d.title);
      if (f.isEmpty) {
        out.add(d); // 标题里没有任何实义字符（或本来就空），交给后面的校验
        continue;
      }
      if (seen.contains(f)) continue; // 撞了 → 丢掉
      seen.add(f);
      out.add(d);
    }
    return out;
  }

  /// 标题指纹：去掉所有标点/空白/大小写，只留实义字符。
  ///
  /// 这样「抄书是最没用的努力」「抄书是最没用的努力！」「抄书是最没用的努力 」
  /// 会得到同一个指纹——它们对用户来说就是同一张卡。
  ///
  /// **不做语义相似**：那要 embedding，成本远超收益；
  /// 真正"意思一样但用词完全不同"的重复交给提示词的 [existingTitles] 去防。
  static String _fingerprint(String title) {
    final sb = StringBuffer();
    for (final r in title.trim().toLowerCase().runes) {
      final ch = String.fromCharCode(r);
      if (RegExp(r'[\u4e00-\u9fff0-9a-zA-Z]').hasMatch(ch)) sb.write(ch);
    }
    return sb.toString();
  }

  /// 把预留里那几张的标题也记进来（它们是"下次要展示的"，也属于"已经生成过"）。
  void _rememberReserved(Iterable<FeedDraft> reserved) {
    _rememberTitles(reserved.map((d) => d.title));
  }

  /// 清空池子（换来源时用）。
  ///
  /// 换了来源就该重新生成——池子里那批是从旧来源长出来的，
  /// 留着会让用户以为选择没生效。
  void clearPool() {
    _pool.clear();
    // 换了来源，「哪些块 / 哪些标题用过」也跟着失效——
    // 旧来源的记忆只会让新来源的素材被无谓地跳过。
    _recentNoteIds.clear();
    _recentChunks.clear();
    _recentTitles.clear();
  }

  // ==========================================================================
  // 跨启动预留
  //
  // ## 流程（每次进入都会跑）
  //
  // ```
  // ① 先试着从 feed_reserve 表里拉上次存的 3 条（消费即清）
  // ② 有 → 就用它当这一屏，**这次不申请**；同时后台申请新的 6 张
  //        给下拉刷新用（前 3 张进池子，后 3 张入库留给再下次）
  // ③ 没有 → 才申请 6 张：前 3 张当屏，后 3 张入库留给下次
  // ```
  //
  // 于是：
  //   · 库里有预留 → 进入**秒出**，不花一次生成的等待
  //   · 库里没有   → 当场申请（第一次装 App 必然走这条）
  //
  // ## 它不影响列表的追加/替换
  //
  // 列表行为由 `InboxPage._loadBatch(first:)` 决定（首次替换、
  // 下拉前向追加）。这里只负责"池子里有什么牌"。
  // ==========================================================================

  /// 进入时的填充。**优先用数据库里的预留**，没有才申请。
  ///
  /// 返回 true 表示池子已填好。
  ///
  /// 任何一步失败都不抛出——失败了大不了走 `takeBatch` 的按需生成，
  /// 让进入因为一次填充失败而卡住是本末倒置。
  /// [override] **仅供测试**，见 [takeBatch]。
  Future<bool> warmUpIfNeeded([FeedSource? override]) async {
    final source = override ?? await resolveSource();
    if (source.isEmpty) return false;

    var reserved = const <FeedDraft>[];
    try {
      // ---- ① 先拉上次存的 ----
      reserved = await _db.takeFeedReserve();

      // ---- ② 有预留：直接当这一屏，不申请 ----
      //
      // 这就是"秒出"：用户不用等生成。新的一批留给下拉刷新。
      if (reserved.isNotEmpty) {
        _pool.addAll(reserved);
        // 预留那几张也是"已经生成过"的，列进标题记忆里避免下一批撞车
        _rememberReserved(reserved);
        // 用现成的 [refill] 补池子，**不要另起一个生成**：
        // refill 内部有 `_inflight` 防重入，而紧接着 `takeBatch` 自己也会
        // 调 refill——另起一个会导致进入时并发跑两次生成（双倍 token）。
        //
        // 补完再把末尾 3 张留到下次。
        unawaited(_fillPoolForNextTime(source));
        return true;
      }

      // ---- ③ 没有预留：才申请 ----
      final materials = await gatherSources(
        source,
        limit: kFeedGenerateCount,
      );
      if (materials.isEmpty) return false; // 没素材，生成不出

      final drafts = await _ai.generateFeedNotes(
        materials,
        count: kFeedGenerateCount,
      );
      _pool.addAll(drafts);

      // 先给下次留好。放在 await 路径上是刻意的：**写库要写稳**，
      // 否则用户进入后立刻杀掉 App，这次就没留下预留，下次又得等生成。
      await _reserveTail();

      // 再把池子补起来。**这一行不能省**：
      // `_reserveTail` 抽走 kFeedReserveSize 张之后，池子可能只剩一屏，
      // 首屏一取就空 —— 用户第一次下拉就要等生成。
      // 不 await：它在后台跑，不影响首屏显示。
      _refillInBackground(source);
      return true;
    } catch (_) {
      // 失败：不抛，但**必须把已取出的预留放回池子**——
      // 表里已经删了，不还回去就真的丢了。
      if (reserved.isNotEmpty && _pool.isEmpty) _pool.addAll(reserved);
      return false;
    }
  }

  /// 后台补池（fire-and-forget）。
  ///
  /// ## 为什么必须在这里吞异常
  ///
  /// 这几处调用都在 `unawaited` 里，异常没人接 → 变成**未捕获的异步错误**。
  /// 实测踩过：`warmup_test` 的 `tearDown` 关掉数据库之后，后台任务才走到
  /// 查库那一步，于是抛出
  /// `Bad state: Can't re-open a database after closing it`，
  /// 而这个异常被算到**上一个测试**头上，看起来像完全无关的失败。
  ///
  /// 吞掉是安全的：补池是**尽力而为**——真失败了下拉刷新时
  /// [takeBatch] 会按需生成，用户不会缺内容。
  ///
  /// 但不能吞得无声无息，所以打一行日志（测试里不刷屏、真机上能查）。
  void _refillInBackground(FeedSource source) {
    refill(source).catchError((Object e) {
      debugPrint('[Feed] 后台补池失败（忽略）：$e');
    });
  }

  /// 后台补一批，给下次下拉刷新用；顺便把末尾几张留给再下次。
  ///
  /// **不 await**：这是给"下一次"准备的，不该让这一屏等它。
  /// 失败无所谓——下拉时 [takeBatch] 会按需生成。
  ///
  /// 整套步骤都包在 try/catch 里（理由见 [_refillInBackground]）：
  /// 它是**唯一**会同时碰 `refill` 和 `_reserveTail` 的后台任务，
  /// 而 `_reserveTail` 失败（比如库已关闭）同样会变成未捕获的异步错误。
  ///
  /// 注意：走的是 [refill]，它内部有 `_inflight` 防重入，
  /// 所以和 `takeBatch` 自己的 refill 不会并发跑两次生成。
  Future<void> _fillPoolForNextTime(FeedSource source) async {
    try {
      await refill(source);
      await _reserveTail();
    } catch (e) {
      debugPrint('[Feed] 后台补池 / 留预留失败（忽略）：$e');
    }
  }

  /// 把池子**末尾**的 [kFeedReserveSize] 张存进 `feed_reserve` 并删掉它们。
  ///
  /// 存末尾而不是开头：开头那几张是这一屏马上要展示的，
  /// 存它们会导致"下次打开看到和这次一样的内容"。
  ///
  /// 存完**从内存池删除**——它们已经落到表里，留在池子里会被当成
  /// "下一批"重复展示。
  Future<void> _reserveTail() async {
    if (_pool.length <= kFeedBatchSize) return; // 不够一屏，没得留

    final spare = _pool.length - kFeedBatchSize;
    final take = spare < kFeedReserveSize ? spare : kFeedReserveSize;
    final tail = _pool.sublist(_pool.length - take);

    await _db.replaceFeedReserve(tail);
    _pool.removeRange(_pool.length - take, _pool.length);
  }
}
