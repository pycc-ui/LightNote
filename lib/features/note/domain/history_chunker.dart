import '../../../core/db/app_database.dart';
import '../../../core/util/app_params.dart';

/// 会话历史的一片。
///
/// ## 与笔记切片最大的不同：**不落库、不需要偏移**
///
/// 笔记的片存进了 `note_chunks`，所以只能存"原文的哪一段"（偏移），
/// 否则等于把正文再存一份。而会话切片**每次现算、不存**（见
/// [HistoryChunker] 的说明），所以这里**直接带正文**，省掉偏移那一层
/// 间接与随之而来的"偏移过期"问题。
class HistoryChunk {
  const HistoryChunk({
    required this.index,
    required this.text,
    required this.at,
    required this.roles,
    required this.userSnippet,
  });

  /// 顺序号。**从最早的一轮开始数**，这样新的一轮只会往后追加，
  /// 旧片的 index 不会变（会话是只增的）。
  final int index;

  /// 已渲染好的片正文（带角色标注，见 [HistoryChunker.render]）。
  final String text;

  /// 这一片里**最早**那条消息的时间。
  final DateTime at;

  /// 这一片包含哪些角色，例如 `['user', 'assistant']`。
  final List<String> roles;

  /// 用户那句话的开头几十字，给目录当标题用。
  final String userSnippet;

  int get charCount => text.length;

  @override
  String toString() =>
      'HistoryChunk(#$index, $charCount 字, ${roles.join("+")})';
}

/// 把会话历史切成片。**不落库**，每次现算。
///
/// 一片 = 一轮，这个选择一次解决三件事：
///
/// 1. **角色清晰**：AI 知道哪句是用户说的、哪句是自己说的
/// 2. **索引天然稳定**：新的一轮只**追加**新片，旧片的 index 不变
/// 3. **满足协议约束**：切掉带 `tool_calls` 的 assistant 消息、却留下对应的
///    `tool` 结果，API 会**直接报错**。而"一片 = 一整轮、一轮包含它内部的
///    全部 tool 消息"，边界永远落在完整轮次上，**不可能切出半个工具调用链**
///
/// 不像笔记那样落库：
///
/// | 维度 | 笔记切片 | 会话切片 |
/// |---|---|---|
/// | 搜索要返回"命中哪一片" | 要 | 不要 |
/// | 数据变化频率 | 只有用户编辑时 | **每问一句就追加** |
/// | 落库的代价 | 建表 + 重切链路 | **表跟着对话无限增长** |
///
/// 几十轮现算就是毫秒级，落库没有收益。
class HistoryChunker {
  HistoryChunker._();

  /// 上限（与笔记切片同一套）。超过就用更深的分隔继续拆。值见 `ChunkLimits`。
  static const cap = ChunkLimits.historyCap;

  /// 下限（尽力而为）。低于它的相邻轮会合并。
  static const floor = ChunkLimits.historyFloor;

  /// 目录里"用户那句话"的摘要长度。
  static const userSnippetChars = ChunkLimits.historyUserSnippetChars;

  /// 一条消息在片里的角色标注。
  static const userLabel = '【用户】';
  static const assistantLabel = '【我】';

  /// 切分入口。[messages] 必须**按时间正序**。
  static List<HistoryChunk> chunk(List<AiMessage> messages) {
    if (messages.isEmpty) return const [];

    final rounds = _toRounds(messages);
    if (rounds.isEmpty) return const [];

    // ① 逐轮渲染，超上限的轮先拆开
    final pieces = <_Piece>[];
    for (final r in rounds) {
      pieces.addAll(_fit(r));
    }

    // ② 顺序贪心合并（与笔记切片同一套规则：**不越上限**）
    final merged = _merge(pieces);

    // ③ 编号
    return [
      for (var i = 0; i < merged.length; i++)
        HistoryChunk(
          index: i,
          text: merged[i].text,
          at: merged[i].at,
          roles: merged[i].roles,
          userSnippet: merged[i].userSnippet,
        ),
    ];
  }

  /// 目录用：只要元数据，**不带正文**（省 token 的关键）。
  static List<Map<String, Object?>> catalog(List<AiMessage> messages,
      {int limit = 20, int max = 50}) {
    final all = chunk(messages);
    if (all.isEmpty) return const [];
    final take = limit.clamp(0, max);
    // 目录给**最近**的若干片：用户问"我们刚才聊了什么"时最可能是这些。
    final from = all.length > take ? all.length - take : 0;
    return [
      for (final c in all.skip(from))
        {
          'index': c.index,
          'at': _stamp(c.at),
          'roles': c.roles,
          'userSnippet': c.userSnippet,
          'charCount': c.charCount,
        },
    ];
  }

  /// 按 index 取片（[readChunk] 的会话版）。越界返回空列表。
  static List<HistoryChunk> slice(List<AiMessage> messages,
      {required List<int> indexes, int maxPieces = 3, int maxChars = 1500}) {
    final all = chunk(messages);
    final out = <HistoryChunk>[];
    var used = 0;
    for (final i in indexes) {
      if (out.length >= maxPieces) break;
      if (i < 0 || i >= all.length) continue;
      final c = all[i];
      if (used + c.charCount > maxChars && out.isNotEmpty) break;
      out.add(c);
      used += c.charCount;
    }
    return out;
  }

  // ==========================================================================
  // 内部
  // ==========================================================================

  /// 按轮分组：一条 `user` 开启一轮，直到下一条 `user` 之前（含 assistant / tool）。
  static List<_Round> _toRounds(List<AiMessage> messages) {
    final sorted = [...messages]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final rounds = <_Round>[];
    _Round? cur;
    for (final m in sorted) {
      // 用局部变量接一下：`cur` 是可空的局部，Dart 不会跨 `||` 提升它。
      var r = cur;
      if (r == null || m.role == 'user') {
        r = _Round(at: m.createdAt);
        rounds.add(r);
      }
      r.messages.add(m);
      cur = r;
    }
    return rounds;
  }

  /// 把一轮渲染成片；超过 [cap] 就按段落拆。
  ///
  /// 一轮内部**只有 user / assistant 的正文会进片**：`tool` 结果是机器的中间产物，
  /// 对"回看我们聊了什么"没有价值，放进去只是烧 token。
  /// （但轮次的**边界**仍然包含它们，所以工具调用链不会被切断。）
  static List<_Piece> _fit(_Round round) {
    final body = render(round.messages);
    if (body.isEmpty) return const [];

    final snippets = _userSnippets(round.messages);
    if (body.length <= cap) {
      return [
        _Piece(
          text: body,
          at: round.at,
          roles: _rolesOf(round.messages),
          userSnippet: snippets,
        ),
      ];
    }

    final out = <_Piece>[];
    for (final part in _splitLong(body)) {
      out.add(_Piece(
        text: part,
        at: round.at,
        roles: _rolesOf(round.messages),
        userSnippet: snippets,
      ));
    }
    return out;
  }

  /// 超长文本先按段落（空行）拆，段落还超就按句子拆，句子还超才按字符硬切。
  static List<String> _splitLong(String text) {
    final out = <String>[];
    for (final para in text.split(RegExp(r'\n\s*\n'))) {
      final p = para.trim();
      if (p.isEmpty) continue;
      if (p.length <= cap) {
        out.add(p);
        continue;
      }
      for (final s in _bySentence(p)) {
        if (s.length <= cap) {
          out.add(s);
        } else {
          for (var i = 0; i < s.length; i += cap) {
            out.add(s.substring(i, i + cap > s.length ? s.length : i + cap));
          }
        }
      }
    }
    return out;
  }

  /// 按句末标点切，**保留标点在前一句末尾**。累积到接近 [cap] 就断。
  static List<String> _bySentence(String text) {
    final out = <String>[];
    final buf = StringBuffer();
    for (final ch in text.split('')) {
      buf.write(ch);
      final isEnd = '。！？!?…\n'.contains(ch);
      if (isEnd && buf.length >= cap) {
        out.add(buf.toString().trim());
        buf.clear();
      }
    }
    final rest = buf.toString().trim();
    if (rest.isNotEmpty) out.add(rest);
    return out;
  }

  /// 顺序贪心合并：**只在合起来不超上限时**才并，与笔记切片同一套规则。
  static List<_Piece> _merge(List<_Piece> pieces) {
    if (pieces.isEmpty) return const [];
    final out = <_Piece>[];
    _Piece? cur;
    for (final p in pieces) {
      if (cur == null) {
        cur = p;
        continue;
      }
      final canMerge =
          cur.charCount < floor && cur.charCount + p.charCount <= cap;
      if (canMerge) {
        cur = cur.merge(p);
      } else {
        out.add(cur);
        cur = p;
      }
    }
    if (cur != null) out.add(cur);
    return out;
  }

  /// 把一轮的消息渲染成可读文本。
  ///
  /// 空正文的 `assistant`（只提了工具、还没回答的那种占位）**跳过**，
  /// 否则片里会多出一行光秃秃的 `【我】`。
  static String render(List<AiMessage> round) {
    final b = StringBuffer();
    for (final m in round) {
      final text = m.content.trim();
      if (text.isEmpty) continue;
      final label = switch (m.role) {
        'user' => userLabel,
        'assistant' => assistantLabel,
        _ => null, // tool / system 不进片
      };
      if (label == null) continue;
      if (b.isNotEmpty) b.write('\n\n');
      b.write('$label$text');
    }
    return b.toString();
  }

  static List<String> _rolesOf(List<AiMessage> round) {
    final seen = <String>[];
    for (final m in round) {
      if (m.content.trim().isEmpty) continue;
      if ((m.role == 'user' || m.role == 'assistant') && !seen.contains(m.role)) {
        seen.add(m.role);
      }
    }
    return seen;
  }

  static String _userSnippets(List<AiMessage> round) {
    final u = round.where((m) => m.role == 'user').firstOrNull;
    final t = (u?.content ?? '').trim().replaceAll('\n', ' ');
    return t.length <= userSnippetChars
        ? t
        : '${t.substring(0, userSnippetChars)}…';
  }

  static String _stamp(DateTime utc) {
    final l = utc.toLocal();
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${p2(l.month)}-${p2(l.day)} ${p2(l.hour)}:${p2(l.minute)}';
  }
}

/// 一轮对话（从一条 user 到下一条 user 之前）。
class _Round {
  _Round({required this.at});
  final DateTime at;
  final List<AiMessage> messages = [];
}

/// 一片的中间形态。合并时要把两个 piece 并成一个。
class _Piece {
  const _Piece({
    required this.text,
    required this.at,
    required this.roles,
    required this.userSnippet,
  });

  final String text;
  final DateTime at;
  final List<String> roles;
  final String userSnippet;

  int get charCount => text.length;

  _Piece merge(_Piece other) => _Piece(
        text: '${text.trimRight()}\n\n${other.text.trimLeft()}',
        at: at,
        roles: [...roles, ...other.roles.where((r) => !roles.contains(r))],
        userSnippet: userSnippet,
      );
}
