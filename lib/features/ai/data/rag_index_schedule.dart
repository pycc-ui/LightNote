import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../../../core/db/app_database.dart';
import 'rag_indexer.dart';

/// **索引的后台调度**：谁改了笔记就补谁的向量，空闲时补一批老笔记。
///
/// ## 为什么不是"改完就同步索引"
///
/// 嵌入一条要 **74ms 的纯 CPU**（实测，333 字）。而 `NoteRepository.saveContent`
/// 是编辑页防抖 500ms 后 **await** 的 —— 在那里同步索引，等于用户每停一次手就
/// 多等几百毫秒到几秒。所以索引**永远不参与保存**：保存只管把正文写进库，
/// 向量慢慢补，落后几秒没有任何影响（检索本来就是锦上添花那一路）。
///
/// ## 为什么不用定时器
///
/// 用"脏集合 + 一个在跑的循环"代替 `Timer` 防抖：
///   · **不会漏**：连续改 10 次只是把同一个 id 放进集合，跑的时候取一次；
///   · **没有定时器**：定时器在 widget 测试里会被判"还在挂着"（测试结束时
///     报 `A Timer is still pending`），而这个循环在测试里根本不启动
///     （见 [start]，测试不调它 → [instance] 是 null → 调用点一行都不执行）。
///
/// ## 为什么是"启动后才生效"
///
/// [start] 由 App 启动流程显式调用。测试里没人调它，于是：
///   · 不建定时器、不跑后台任务；
///   · **也不会有"库已经关了、后台还在查库"那种错** —— 那个错误会被算到
///     *上一个*测试头上，看起来像完全无关的用例挂了（`feed_repository` 里
///     踩过同一个坑，注释还留着）。
class RagIndexSchedule {
  RagIndexSchedule._(AppDatabase db) : _indexer = RagIndexer(db);

  final RagIndexer _indexer;

  static RagIndexSchedule? _instance;

  /// 已生效的调度器；**没 [start] 过就是 null**（测试里就是这种情况）。
  static RagIndexSchedule? get instance => _instance;

  /// App 启动时调一次（幂等）。测试不要调。
  static RagIndexSchedule start(AppDatabase db) =>
      _instance ??= RagIndexSchedule._(db);

  /// 关掉（测试收尾用；App 里让它活到进程结束）。
  static void stop() => _instance = null;

  /// 待补的笔记（顺带起到去重作用）。
  final _dirty = <String>{};

  /// 有没有人要求"补一批老笔记"。
  bool _backfillWanted = false;

  /// 有没有人要求"清一批死向量"。
  bool _housekeepingWanted = false;

  /// 当前那一轮循环（非空 = 正在跑）。
  Future<void>? _running;

  /// 这一轮已经补了几片（给测试断言"确实干活了"用）。
  int _indexedThisRun = 0;
  int get indexedThisRun => _indexedThisRun;

  /// 这一轮清掉了几行死向量。
  int _prunedThisRun = 0;
  int get prunedThisRun => _prunedThisRun;

  /// 已经报过错的种类（同一类只报一次，免得每篇笔记刷一条）。
  final _reported = <String>{};

  /// 报一次错。
  ///
  /// **这是设备上唯一能看出"语义检索为什么没生效"的地方** —— 索引是静默的，
  /// 模型加载不起来的话表现只是"检索永远返回 null"，不打日志根本查不出来。
  /// 而且只报第一次：一类错通常一次就是全部（比如原生库加载失败）。
  void _reportOnce(String what, Object error) {
    if (!_reported.add(what)) return;
    debugPrint('[LightNote] 语义索引：$what → $error');
  }

  /// 某篇笔记的正文变了（保存路径调，**不 await**）。
  void noteChanged(String noteId) {
    _dirty.add(noteId);
    _pump();
  }

  /// 补一批还缺向量的老笔记（启动、进 AI 页时调，**不 await**）。
  void kickBackfill() {
    _backfillWanted = true;
    _pump();
  }

  /// 顺手清一批**死向量**（笔记改过 / 模型换过 / 笔记已软删）。
  ///
  /// 为什么只在启动时清、且不清干净：死行**不影响任何检索结果**
  ///（`validVectors` 的 JOIN 就把它们过滤掉了），留着只是占地方。
  /// 每次启动清一批（默认 500 行），跑几天自然就干净了 ——
  /// 为这点空间加定时器、加后台任务不值得。
  void kickHousekeeping() {
    _housekeepingWanted = true;
    _pump();
  }

  /// 把当前排队的活干完（**测试用**：不然断言会跑在索引完成之前）。
  Future<void> drain() async {
    await _pump();
    // `_pump` 在"已经在跑"时直接返回，所以要再等一轮真正结束
    while (_running != null) {
      await _running;
    }
  }

  /// 起一轮循环。已经在跑就直接返回（脏集合里的东西会被那一轮顺手带走）。
  Future<void> _pump() {
    final running = _running;
    if (running != null) return running;
    final f = _loop();
    _running = f;
    return f;
  }

  Future<void> _loop() async {
    _indexedThisRun = 0;
    try {
      // ---- ① 先补"刚改过的"（用户正等着用，优先级高）----
      while (_dirty.isNotEmpty) {
        final id = _dirty.first;
        _dirty.remove(id);
        try {
          _indexedThisRun += await _indexer.indexNote(id);
        } catch (e) {
          // 单篇失败不影响别的（笔记可能刚被删、模型可能没加载起来）
          _reportOnce('补这篇的向量失败（$id）', e);
        }
      }

      // ---- ② 再补老笔记（一批就走，剩下的下次启动/进 AI 页再补）----
      if (_backfillWanted) {
        _backfillWanted = false;
        try {
          _indexedThisRun += await _indexer.indexMissing();
        } catch (e) {
          // 同上：补索引是尽力而为
          _reportOnce('批量补索引失败', e);
        }
      }

      // ---- ③ 清死向量（放在最后：它最不重要，前面没干完就先不干）----
      if (_housekeepingWanted) {
        _housekeepingWanted = false;
        try {
          _prunedThisRun = await _indexer.pruneStale();
        } catch (e) {
          _reportOnce('清理死向量失败', e);
        }
      }
    } finally {
      _running = null;
    }

    // 只在真的补到了东西时打一行 —— 设备上验证"索引到底动没动"就靠它。
    // 没补到是常态（都补完了、或者库是空的），不打，免得刷屏。
    if (_indexedThisRun > 0) {
      debugPrint('[LightNote] 语义索引：补了 $_indexedThisRun 片');
    }
  }
}
