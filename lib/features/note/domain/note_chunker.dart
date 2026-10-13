/// 把笔记正文切成一片片"原文区间"（`NoteChunk`）。
///
/// 这是一个纯函数：输入正文、输出片列表，不碰数据库。落库、搜索定位、卡片流取素材
/// 三处都用它，同输入同输出——所以搜索结果里的片号与阅读态渲染出的片号必然对得上。
/// （结果是否要存进 `note_chunks` 表由 `NoteChunkRepository` 决定，见《数据库设计》。）
///
/// 切分是分层的：先按标题层次递归切，只在标题用尽时才动段落 / 句子。这样每一片天然
/// 落在"一个话题"里，而且带上标题路径当上下文。（若累积到固定字数就切，片不知道自己
/// 来自哪一节的标题，AI 拿到一段原文却没有任何上下文；超长段落平均劈也会横跨两个话题。）
///
/// 切分顺序（严格按这个顺序）：
///
/// ```
/// 1. 按标题层次切：`#`~`######` 行把正文切成"节"（第一个标题之前也算一节）
/// 2. 节 ≤ cap → 保留；节 > cap → 用它内部更深一级的标题继续切，递归
/// 3. 标题用尽（到 6 级）还超 cap → 按段落（空行）切成"原子单元"
/// 4. 单元还超 cap：
///      · 不可拆散单元（围栏代码块 / 连续表格行 / 连续引用行 / 连续列表项）
///        → 不拆，允许超 cap；但超过 atomicCeiling 时按行切（见下）
///      · 其余 → 句子 → 子句 → 字符硬切
/// 5. 小片合并：顺序贪心，绝不越 cap
/// 6. 填 index / heading / level / contentHash
/// ```
///
/// 偏移基于原始 `content`，不归一化：不把 CRLF 折成 LF，也不 trim 后再算下标。
/// `start` / `end` 是原始 `content` 上的下标，
/// `chunk(c)[i].textOf(c) == c.substring(start, end)` 逐字成立。代价是片与片之间允许
/// 留空隙（首尾空白、分隔空行不进任何片），但任何非空白字符都必定落在某一片里。
///
/// 不可拆散单元的 1500 硬顶来自 `readChunk`（AI 读片）当年的单次预算：一片若超过 1500，
/// AI 根本读不进来。Agent 改成命令语言后不再读片，但"片不能无限大"这个约束仍然成立，
/// 所以超过 1500 就按行切——宁可拆散，也不切出一片过大的东西。
library;

import '../../../core/util/app_params.dart';
import 'note_chunk.dart';

/// 切片器本体。
class NoteChunker {
  NoteChunker._();

  /// 上限（硬约束）。除了不可拆散单元，任何一片都不超过它。值见 `ChunkLimits`。
  static const cap = ChunkLimits.noteCap;

  /// 下限（**期望值**，不参与合并判断）。
  ///
  /// ⚠️ 合并是"**填到上限为止**"，不是"填到下限就停"：设计里那个
  /// 1400 字 → `600 / 600 / 200` 的例子就是填到接近 700 才停
  /// （200×3 = 600，第 4 个会到 800 > cap）。所以这个常量**不参与逻辑**，
  /// 只用来表达"不该切出一堆碎片"这个期望（测试也据此断言）。
  static const floor = ChunkLimits.noteFloor;

  /// 短笔记不上标题、不分段，整篇一片。
  static const shortNoteLimit = ChunkLimits.noteShortLimit;

  /// 不可拆散单元的硬顶。超过它就得拆——理由见类注释。
  static const atomicCeiling = ChunkLimits.noteAtomicCeiling;

  /// 句末标点（把超长段落拆成句子；分隔符留在前一片末尾）。
  static final _sentenceEnd = RegExp(r'[。！？!?…]+');

  /// 子句标点（句子还太长时再拆）。
  static final _clauseEnd = RegExp(r'[，；,;：:]+');

  /// 切分入口。返回的每一片都是**原文的连续区间**（不加工、不失真）。
  ///
  /// 正文为空（或只有空白）返回空列表——调用方据此跳过这篇笔记。
  static List<NoteChunk> chunk(String content) {
    if (content.isEmpty) return const [];
    // 空行/换行识别一律走 _lineStart/_isBlank：`\r` 属于上一行，
    // 不会在 CRLF 文本里多出一个"空行"。
    if (_isBlank(content)) return const [];

    // 短笔记兜底：**没有标题**的短笔记整篇一片（连首尾空白一起保真）。
    //
    // ⚠️ 条件里的"没有标题"是必须的：只看长度的话，带标题的短笔记也会被压成
    // "1 片、heading 为空、level 0"，整条分层流程被绕过——标题路径白写了，
    // AI 与搜索页都拿不到上下文。
    //
    // 而且这个兜底本来要避免的是"把一段**没有结构**的短文按句子剁碎"；
    // 有标题就说明有结构，那就不该兜底。
    if (content.length <= shortNoteLimit && !_hasHeading(content)) {
      // 首尾空白不进任何片 —— 这条对兜底路径同样成立：直接返回整篇
      // `[0, length)` 的话，`'  \n\n正文\n\n  '` 的片首尾都会挂着空白。
      final whole = _trim(content, _Piece(0, content.length, '', 0, false));
      if (whole == null) return const [];
      return [_mk(content, whole, 0)];
    }

    final out = <_Piece>[];
    for (final s in _parseSections(content, 0, content.length)) {
      for (final p in _splitSection(content, s)) {
        // 边界收进非空白：首尾空白不进任何片（同时顺手丢掉整片空白的碎片）
        final t = _trim(content, p);
        if (t != null) out.add(t);
      }
    }
    return _mergeAndIndex(content, out);
  }

  // ==========================================================================
  // 第 1、2 步：按标题层次递归切
  // ==========================================================================

  /// 一"节"：一段区间 + 它生效的标题路径 + 层级。
  ///
  /// [start] 指向标题行的行首（无标题的节指向内容的第一个字符）；
  /// [contentStart] 指向**正文**起点（有标题时是标题行**之后**，
  /// 也就是换行之后——落在换行符上会把"行"算错一行）。
  static List<_Section> _parseSections(String c, int from, int to) {
    final heads = <_Head>[];
    for (final ls in _lineStart(c, from, to)) {
      final h = _parseHeading(c, ls, _lineEnd(c, ls, c.length));
      if (h != null && h.lineEnd <= to) heads.add(h);
    }

    final out = <_Section>[];
    if (heads.isEmpty) {
      return [_Section(from, to, from, '', 0)];
    }

    // 第一个标题之前的内容：独立一节，标题为空（可能只有空白 → 不产出）
    out.add(_Section(from, heads.first.start, from, '', 0));

    /// 当前生效的标题栈：`path[lv]` 是第 lv 级标题的文本。
    ///
    /// 每遇到一个标题，先把**它这一级及更深**的残留清空，再把自己放进去——
    /// 这样"遇到更高级的标题就丢掉更深层遗留"是自动成立的
    /// （`# A` → `## B` → `# C` 之后，C 的路径就是 `C` 而不是 `A / B / C`）。
    final path = List<String>.filled(7, '');

    for (var i = 0; i < heads.length; i++) {
      final h = heads[i];
      for (var lv = h.level; lv <= 6; lv++) {
        path[lv] = '';
      }
      path[h.level] = h.text;

      // 完整路径：从 1 级拼到自己这一级，只留非空的（层级可以跳，例如 # 直接到 ###）
      final full = [
        for (var lv = 1; lv <= h.level; lv++)
          if (path[lv].isNotEmpty) path[lv],
      ].join(' / ');

      final next = i + 1 < heads.length ? heads[i + 1].start : to;
      final cs = _afterLine(c, h.lineEnd, next);
      out.add(_Section(h.start, next, cs, full, h.level));
    }
    return out;
  }

  /// 递归切一节：先看内部有没有更深的标题，再看段落。
  static List<_Piece> _splitSection(String c, _Section s) {
    // ⚠️ 起点用**节的起点 `s.start`**（含标题行），**不是**"标题之后的正文"。
    //
    // 标题行的文字本身就是内容：像 `# AA的正文` 这种笔记，每节只有标题行有字，
    // 从标题之后开始会让每节都变成空片 —— 整篇内容一片不剩。
    // 而且"标题与它下面的正文在同一片里"本来就是要的行为：
    // 读片的人得看到这片讲的是哪一节。
    final start = s.start;
    final end = s.end;

    // 整段都是空白 → 不产出。留着它有害：长度 0 会在合并时把后面那片吞掉。
    //
    // ⚠️ 判据必须覆盖 **[start, end) 整段**，不能只看"标题之后的正文"：
    // 像 `# AA的正文` 这种笔记，每节的正文**全在标题行里**，只看"标题之后"
    // 会把每一节都当成空的丢掉 —— 整篇一片不剩。
    if (_trim(c, _Piece(start, end, s.heading, s.level, false)) == null) {
      return const [];
    }

    if (end - start <= cap) {
      return [
        _Piece(start, end, s.heading, s.level,
            _isProtected(c, start, s.contentStart)),
      ];
    }

    // 内部标题（**严格更深**）的位置：比本节的标题更深才算它的下一层。
    // 行尾按**整篇正文**算（不按 s.end 截断）——否则跨在节边界上的标题行
    // 会被截成半行，`_parseHeading` 直接认不出来，于是这一节就再也切不开。
    final bounds = <_Head>[];
    final dls = _lineStart(c, s.contentStart, end);
    for (final ls in dls) {
      final h = _parseHeading(c, ls, _lineEnd(c, ls, c.length));
      if (h != null && h.level > s.level && h.lineEnd <= end) bounds.add(h);
    }
    if (bounds.isNotEmpty) {
      final out = <_Piece>[];
      for (var i = 0; i < bounds.length; i++) {
        final b = bounds[i];
        final bEnd = i + 1 < bounds.length ? bounds[i + 1].start : end;
        out.addAll(
          _splitSection(c, _Section(b.start, bEnd,
              _afterLine(c, b.lineEnd, bEnd), b.text, b.level)),
        );
      }
      // 本层标题之后、下一层标题之前的那一段属于**本节**，
      // 所以路径用本节的 heading（更深的内容已经跟着各自的小节走了）
      if (bounds.first.start > start) {
        final lead = _Section(
          start,
          bounds.first.start,
          s.contentStart,
          s.heading,
          s.level,
        );
        if (lead.length > 0) out.insertAll(0, _splitSection(c, lead));
      }
      return out;
    }

    // 标题用尽 → 段落 → 原子单元 → 超 cap 再拆
    final out = <_Piece>[];
    for (final u in _collectUnits(c, start, end)) {
      final frag = _Frag(u.start, u.end, s.heading, s.level, u.protected);
      if (frag.length <= cap) {
        out.add(frag.toPiece());
      } else {
        out.addAll(_splitOversized(c, frag));
      }
    }
    return out;
  }

  /// 把一片的边界收到**非空白**处：首尾空白不进任何片。
  ///
  /// 收完是空的（整片都是空白）返回 null，调用方据此丢掉。
  ///
  /// 为什么在这里统一做、而不是切的时候各自小心：切分有四五条路径
  /// （标题递归 / 段落 / 句子 / 字符硬切），每条都记得 trim 迟早漏一条。
  static _Piece? _trim(String c, _Piece p) {
    var s = p.start;
    var e = p.end;
    while (s < e && c[s].trim().isEmpty) {
      s++;
    }
    while (e > s && c[e - 1].trim().isEmpty) {
      e--;
    }
    if (e <= s) return null;
    return p.span(s, e, p.protected);
  }

  // ==========================================================================
  // 第 3 步：按段落切成原子单元（代码块 / 表格 / 引用 / 列表整体一组）
  // ==========================================================================

  /// 把 [from, to) 按空行切成单元。
  ///
  /// 连续同类行之间插入的空行**不切断**这一组——列表项之间空一行仍是同一个
  /// 列表，表格的写法里也常有空行，切断了就散了。
  static List<_Unit> _collectUnits(String c, int from, int to) {
    final out = <_Unit>[];
    var unitStart = -1;
    var unitEnd = -1;
    var lastEnd = -1;
    var blockStart = -1;
    var lastKind = '';
    var inFence = false;

    void flush() {
      if (unitStart >= 0) {
        out.add(_Unit(unitStart, unitEnd, lastKind.isNotEmpty));
      }
      unitStart = -1;
      unitEnd = -1;
      lastEnd = -1;
      blockStart = -1;
      lastKind = '';
    }

    for (final ls in _lineStart(c, from, to)) {
      final le = _lineEnd(c, ls, to);
      final raw = c.substring(ls, le);

      // 围栏代码块内部：整块收下（围栏行本身就是边界）
      if (inFence) {
        unitEnd = le;
        if (_isFenceLine(raw)) inFence = false;
        continue;
      }

      if (_isBlank(raw)) {
        // 空行：已经吃过表格/引用/列表就还留在同一个单元里（"连续同类行"）
        if (unitStart >= 0 && lastKind.isNotEmpty) continue;
        flush();
        continue;
      }

      var glue = false;
      String kind;
      if (_isFenceLine(raw)) {
        kind = 'fence';
        inFence = true;
      } else if (_isTableLine(raw) && lastKind == 'table') {
        kind = 'table';
        glue = true;
      } else if (_isQuoteLine(raw) && lastKind == 'quote') {
        kind = 'quote';
        glue = true;
      } else if (_startsList(raw)) {
        kind = 'list';
        glue = lastKind == 'list';
      } else if (lastKind == 'list' &&
          lastEnd >= 0 &&
          _indentOf(raw) > _indentOf(c.substring(blockStart, lastEnd))) {
        kind = 'list'; // 列表项自己的续行（缩进更深）
        glue = true;
      } else {
        kind = ''; // 普通段落：上空行已经切开了，这里都是新块
      }

      if (unitStart < 0) {
        unitStart = ls;
        blockStart = ls;
      } else if (!glue) {
        flush();
        unitStart = ls;
        blockStart = ls;
      }
      unitEnd = le;
      lastEnd = le;
      lastKind = kind;
    }
    flush();
    return out;
  }

  // ==========================================================================
  // 第 4 步：单元还超 cap 时继续拆
  // ==========================================================================

  /// 拆一个超 cap 的单元。
  ///
  /// 普通单元 → 句子 → 子句 → 字符硬切。不可拆散单元 → 整块留着（允许超 cap），
  /// 只有超过 [atomicCeiling] 才按行切——那已经不是"片"而是 AI 读不进来的东西了。
  static List<_Piece> _splitOversized(String c, _Frag f) {
    if (f.protected) {
      if (f.length <= atomicCeiling) return [f.toPiece()];
      return _splitByLines(c, f);
    }
    return _splitByCuts(c, f);
  }

  /// 不可拆散单元超过硬顶：**按行**切，宁可拆也不留读不进来的片。
  ///
  /// 判据必须先看单行长度：只做"按行累积、最后吐尾巴"的话，遇到单行就超上限
  /// 的情形（一整段没有换行的超长文本、代码块里一行巨长）会直接返回空列表，
  /// 整篇内容丢光（`'a' * 2000` 就会切出 0 片）。所以一行自己就超上限时，
  /// 只能字符硬切。
  static List<_Piece> _splitByLines(String c, _Frag f) {
    final out = <_Piece>[];
    var pieceStart = -1;
    var pieceEnd = -1;

    void flush() {
      if (pieceStart >= 0 && pieceEnd > pieceStart) {
        out.add(f.sub(pieceStart, pieceEnd).toPiece());
      }
      pieceStart = -1;
      pieceEnd = -1;
    }

    for (final ls in _lineStart(c, f.start, f.end)) {
      final le = _lineEnd(c, ls, f.end);
      if (le <= ls) continue; // 空行不进片

      // 单行自己就超上限 → 先把攒着的吐出来，再硬切这一行
      if (le - ls > cap) {
        flush();
        out.addAll(_hardCut(c, f.sub(ls, le)));
        continue;
      }

      // 攒行；合起来超上限就先定稿
      if (pieceStart >= 0 && le - pieceStart > cap) flush();
      if (pieceStart < 0) pieceStart = ls;
      pieceEnd = le;
    }
    flush();
    return out;
  }

  /// 字符硬切：连行边界都救不了时才走到这里（一整段无换行的超长文本）。
  ///
  /// 切点尽量落在空白处（[_safeCut]），也不切开代理对。
  static List<_Piece> _hardCut(String c, _Frag f) {
    final out = <_Piece>[];
    var i = f.start;
    while (i < f.end) {
      if (f.end - i <= cap) {
        out.add(f.sub(i, f.end).toPiece());
        break;
      }
      var e = _safeCut(c, i, i + cap, f.end);
      // `_safeCut` 在"整段都是非空白"时可能原地不动 → 兜底往前推，
      // 否则这里会**死循环**。
      if (e <= i) e = (i + cap < f.end) ? i + cap : f.end;
      out.add(f.sub(i, e).toPiece());
      i = e;
    }
    return out;
  }

  /// 普通单元：句子 → 子句 → 字符硬切（**分隔符留在前一片末尾**，读起来还是原句）。
  static List<_Piece> _splitByCuts(String c, _Frag f) {
    final text = c.substring(f.start, f.end);
    if (text.length > atomicCeiling) return _splitByLines(c, f);

    final out = <_Piece>[];
    for (final p in _keepAt(text, _sentenceEnd)) {
      out.addAll(_cutAgain(c, f, p, 0));
    }
    return out;
  }

  /// 一个字句段还超 cap → 按子句切；子句还超 → 硬切。
  static List<_Piece> _cutAgain(String c, _Frag f, _Span p, int depth) {
    final frag = f.sub(f.start + p.start, f.start + p.end);
    if (frag.length <= cap) return [frag.toPiece()];

    if (depth == 0) {
      final out = <_Piece>[];
      for (final q in _keepAt(c.substring(frag.start, frag.end), _clauseEnd)) {
        out.addAll(_cutAgain(c, frag, q, 1));
      }
      return out;
    }

    final out = <_Piece>[];
    var i = frag.start;
    while (i < frag.end) {
      final e =
          (i + cap < frag.end) ? _safeCut(c, i, i + cap, frag.end) : frag.end;
      out.add(frag.sub(i, e).toPiece());
      i = e;
    }
    return out;
  }

  // ==========================================================================
  // 第 5、6 步：小片合并 + 填元数据
  // ==========================================================================

  /// 顺序贪心合并（绝不越 [cap]），然后按原顺序编号。
  static List<NoteChunk> _mergeAndIndex(String c, List<_Piece> pieces) {
    final out = <_Piece>[];
    _Piece? cur;
    for (final p in pieces) {
      // 空片先丢掉（零长度的"第一个标题之前"那一节不可能产出内容）
      if (p.length <= 0) continue;

      if (cur == null) {
        cur = p;
        continue;
      }

      // ---- 合并规则（两条，缺一不可）----
      //
      // ① 填到上限为止，不是"填到下限就停"。
      //    设计里那个 1400 字 → `600 / 600 / 200` 的例子就是这条：
      //    200+200+200 = 600（第 4 个会到 800 > cap 700，所以停）。
      //    写成"cur 没到下限才并"会在 400 就停，得到 400/400/… 与例子不符。
      //
      // ② 不跨标题边界。`heading` 是对"这片讲的是什么"的承诺；
      //    把「无标题的前言」和「# 后面的标题」并成一片、heading 却只写其中一个，
      //    等于对另一半撒谎。宁可多一片，也不给假路径。
      final sameSection = cur.heading == p.heading && cur.level == p.level;
      final fits = cur.length + p.length <= cap;

      if (sameSection && fits) {
        cur = cur.span(cur.start, p.end, cur.protected || p.protected);
      } else {
        out.add(cur);
        cur = p;
      }
    }
    if (cur != null) out.add(cur);

    return [
      for (var i = 0; i < out.length; i++) _mk(c, out[i], i),
    ];
  }

  static NoteChunk _mk(String c, _Piece p, int i) {
    return NoteChunk(
      index: i,
      heading: p.heading,
      level: p.level,
      start: p.start,
      end: p.end,
      contentHash: NoteChunk.hashOf(c, p.start, p.end),
    );
  }

  // ==========================================================================
  // 位置工具（**全部基于原始 content，不归一化**）
  // ==========================================================================

  /// 区间 [from, to) 内每一行的起始下标。
  ///
  /// **判据是"这一行从哪开始、到哪结束"，不是"位置上的字符"**——
  /// `[from, to)` 很可能从一行中间开始（递归切子节时就是），
  /// 那时靠 `c[i-1] == '\n'` 判断行首会漏掉第一行之后的所有行。
  static List<int> _lineStart(String c, int from, int to) {
    final out = <int>[];
    var i = from;
    while (i < to) {
      out.add(i);
      int e = i;
      while (e < to && c.codeUnitAt(e) != 10 && c.codeUnitAt(e) != 13) {
        e++;
      }
      if (e >= to) break;
      while (e < to && (c.codeUnitAt(e) == 10 || c.codeUnitAt(e) == 13)) {
        e++;
      }
      i = e;
    }
    return out;
  }

  /// 行 [ls] 的结束下标（**不含换行符**；`\r` 也算行尾，不单独成段）。
  static int _lineEnd(String c, int ls, int to) {
    var e = ls;
    while (e < to && c.codeUnitAt(e) != 10 && c.codeUnitAt(e) != 13) {
      e++;
    }
    return e;
  }

  /// 行尾 [lineEnd] **之后**的下标（跳过换行；CRLF 一起跳），不超过 [limit]。
  static int _afterLine(String c, int lineEnd, int limit) {
    var i = lineEnd;
    while (i < limit && i < c.length) {
      final u = c.codeUnitAt(i);
      if (u != 10 && u != 13) break;
      i++;
    }
    return i;
  }

  /// 不含换行的行内容是否全是空白。
  static bool _isBlank(String raw) => raw.trim().isEmpty;

  /// 正文里有没有任何 Markdown 标题行。
  ///
  /// 只用来决定"短笔记要不要兜底成整篇一片"：有标题就说明有结构，
  /// 那就走分层流程，让每片带上自己的标题路径。
  static bool _hasHeading(String c) {
    for (final ls in _lineStart(c, 0, c.length)) {
      if (_parseHeading(c, ls) != null) return true;
    }
    return false;
  }

  /// 左右都是非空白才算"片内"——片边界只允许落在空白处。
  static bool _isBoundary(String c, int i) {
    final before = i == 0 || c[i - 1].trim().isEmpty;
    final after = i >= c.length || c[i].trim().isEmpty;
    return before && after;
  }

  /// 硬切点不落在空白里时往后微调（不切开代理对，也不切开行）。
  ///
  /// 找不到合法切点就**认在原位**——绝不能一路扫到单元末尾，
  /// 那会把整块都塞进第一片，直接突破 cap。
  static int _safeCut(String c, int start, int i, int end) {
    var j = i;
    if (j > start && _isLowSurrogate(c.codeUnitAt(j))) j--;
    if (_isBoundary(c, j)) return j;
    var k = j;
    while (k < end && !_isBoundary(c, k)) {
      k++;
    }
    return k < end ? k : j;
  }

  static bool _isLowSurrogate(int u) => u >= 0xDC00 && u <= 0xDFFF;

  /// 前面紧贴着一行围栏 → 这一片也是"不可拆散"的。
  ///
  /// 认的是**前一行**而不是本片内容：孤立的收尾围栏本身不含 ```、又不是列表，
  /// 不特殊对待的话它会被搬进别的片里，片和片之间的行序就乱了。
  static bool _isProtected(String c, int unitStart, int contentStart) {
    if (unitStart <= contentStart) return false;
    final prevStart = _prevLineStart(c, unitStart);
    final prevEnd = _lineEnd(c, prevStart, unitStart);
    return _isFenceLine(c.substring(prevStart, prevEnd));
  }

  /// [i] 所在行的**上一行**起始下标。
  static int _prevLineStart(String c, int i) {
    var k = i - 1;
    if (k > 0 && c.codeUnitAt(k - 1) == 13) k--; // 跳过 CRLF 的 LF
    while (k > 0 && c.codeUnitAt(k - 1) != 10) {
      k--;
    }
    return k;
  }

  // ==========================================================================
  // Markdown 行识别（都以**原始行**为准）
  // ==========================================================================

  /// `#`~`######` 开头的标题行 → 标题信息（[start] 是 `#` 在原文里的下标）。
  ///
  /// [lineEnd] 是调用方已经算好的行尾（省一次全行扫描，长文下这是 O(n²) 与 O(n) 的差别）。
  static _Head? _parseHeading(String c, int ls, [int? lineEnd]) {
    final le = lineEnd ?? _lineEnd(c, ls, c.length);
    var i = ls;
    // 只允许空格缩进（最多 3 个），tab 缩进的 # 不算标题
    while (i < le && c[i] == ' ') {
      i++;
    }
    if (i - ls > 3 || i >= le || c[i] != '#') return null;
    var level = 0;
    while (i < le && c[i] == '#') {
      level++;
      i++;
    }
    if (level < 1 || level > 6) return null;
    if (i < le && c[i] != ' ' && c[i] != '\t') return null;
    return _Head(ls, le, level, c.substring(i, le).trim());
  }

  static bool _isFenceLine(String raw) {
    final t = raw.trim();
    return t.startsWith('```') || t.startsWith('~~~');
  }

  static bool _isTableLine(String raw) {
    var i = 0;
    while (i < raw.length && raw[i] == ' ') {
      i++;
    }
    return i < raw.length && raw[i] == '|';
  }

  static bool _isQuoteLine(String raw) {
    var i = 0;
    while (i < raw.length && raw[i] == ' ') {
      i++;
    }
    return i < raw.length && raw[i] == '>';
  }

  static bool _startsList(String raw) {
    var i = 0;
    while (i < raw.length && raw[i] == ' ') {
      i++;
    }
    if (i >= raw.length) return false;
    final ch = raw[i];
    if (ch == '-' || ch == '*' || ch == '+') {
      return i + 1 >= raw.length || raw[i + 1] == ' ' || raw[i + 1] == '\t';
    }
    final u = ch.codeUnitAt(0);
    if (u >= 0x30 && u <= 0x39) {
      var j = i;
      while (j < raw.length) {
        final v = raw[j].codeUnitAt(0);
        if (v < 0x30 || v > 0x39) break;
        j++;
      }
      if (j - i <= 9 && j < raw.length && (raw[j] == '.' || raw[j] == ')')) {
        return j + 1 >= raw.length || raw[j + 1] == ' ' || raw[j + 1] == '\t';
      }
    }
    return false;
  }

  static int _indentOf(String raw) {
    var i = 0;
    while (i < raw.length && raw[i] == ' ') {
      i++;
    }
    return i;
  }

  // ==========================================================================
  // 按标点拆（分隔符留在前一片末尾）
  // ==========================================================================

  static List<_Span> _keepAt(String text, RegExp re) {
    final out = <_Span>[];
    var start = 0;
    for (final m in re.allMatches(text)) {
      if (m.end > start) {
        out.add(_Span(start, m.end));
        start = m.end;
      }
    }
    if (start < text.length) out.add(_Span(start, text.length));
    return out.isEmpty ? [_Span(0, text.length)] : out;
  }
}

// ============================================================================
// 内部结构
// ============================================================================

/// 一行标题。
class _Head {
  const _Head(this.start, this.lineEnd, this.level, this.text);

  /// `#` 在原始正文里的下标（缩进留在片外）。
  final int start;

  /// 标题行的结束下标（不含换行）。
  final int lineEnd;
  final int level;
  final String text;
}

/// 一"节"：标题路径生效的一段区间。
class _Section {
  const _Section(this.start, this.end, this.contentStart, this.heading,
      this.level);

  final int start;
  final int end;

  /// 正文起点：有标题时是标题行之后。
  final int contentStart;
  final String heading;
  final int level;

  int get length => end - start;
}

/// 一个原子单元（段落 / 代码块 / 表格组 / 引用组 / 列表组）。
class _Unit {
  const _Unit(this.start, this.end, this.protected);

  final int start;
  final int end;
  final bool protected;
}

/// 待定稿的一片（还没编号）。
class _Piece {
  const _Piece(this.start, this.end, this.heading, this.level, this.protected);

  final int start;
  final int end;
  final String heading;
  final int level;
  final bool protected;

  int get length => end - start;

  _Piece span(int start, int end, bool protected) =>
      _Piece(start, end, heading, level, protected);
}

/// 单元 / 片段：位置 + 标题 + 是否不可拆散。
class _Frag {
  const _Frag(this.start, this.end, this.heading, this.level, this.protected);

  final int start;
  final int end;
  final String heading;
  final int level;
  final bool protected;

  int get length => end - start;

  _Frag sub(int start, int end) => _Frag(start, end, heading, level, protected);

  _Piece toPiece() => _Piece(start, end, heading, level, protected);
}

/// 相对区间。
class _Span {
  const _Span(this.start, this.end);

  final int start;
  final int end;
}
