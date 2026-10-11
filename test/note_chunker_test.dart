// 切片算法（`NoteChunker`）——**分层切片**。
//
// ## 为什么这个文件重要
//
// 切片算法是"卡片具体性"的**唯一来源**——摘要天生概括，卡片要具体
// 就得靠这段原文。切坏了有两种后果：
//   · 切太碎 → 一块里没有完整信息，卡片还是空
//   · 切散了 → 代码块/表格/列表被劈成两半，语义直接丢失
//
// 而且它是**纯函数**，边界情况多（短笔记、超长单段、代码块、标题孤立、
// CRLF），这些正是手点测不出来的地方。
//
// ## 这一版多守一条更硬的契约：**偏移**
//
// 片不存正文，只存 `[start, end)`。上层读片 = `content.substring(start, end)`。
// 所以"偏移算对了"不是细节，而是这个设计**能不能成立**的前提：
// 偏移错一位，AI 读到的就是被削掉一个字的原文，而且**没有任何报错**。
// 下面每个用例都会顺手断言 `textOf(content) == substring(start, end)`。
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_notes/features/note/domain/note_chunk.dart';
import 'package:smart_notes/features/note/domain/note_chunker.dart';

void main() {
  // ==========================================================================
  // 断言工具
  // ==========================================================================

  /// 偏移契约：每一片都必须**逐字**等于原文那段。
  void expectOffsetsExact(String content, List<NoteChunk> chunks) {
    for (final c in chunks) {
      expect(c.start, greaterThanOrEqualTo(0), reason: 'start 不能为负');
      expect(c.end, greaterThan(c.start), reason: '$c 是空片');
      expect(c.end, lessThanOrEqualTo(content.length), reason: '$c 越界');
      expect(c.charCount, c.end - c.start, reason: 'charCount != end - start');
      expect(
        c.textOf(content),
        content.substring(c.start, c.end),
        reason: '$c 的 textOf 与原文对不上',
      );
      expect(c.contentHash, NoteChunk.hashOf(content, c.start, c.end));
    }
  }

  /// 去掉**所有**空白后再比——片之间可以留空隙，但一个非空白字符都不许丢。
  String strip(String s) => s.replaceAll(RegExp(r'[\s\u3000\u00a0\ufeff]+'), '');

  void expectNoContentLoss(String content, List<NoteChunk> chunks) {
    final joined = chunks.map((c) => c.textOf(content)).join();
    expect(
      strip(joined),
      strip(content),
      reason: '有非空白字符没进任何一片（片之间只允许留空白）',
    );
  }

  /// 片序：不重叠、按原文顺序。
  void expectOrdered(String content, List<NoteChunk> chunks) {
    expectOffsetsExact(content, chunks);
    for (var i = 1; i < chunks.length; i++) {
      expect(chunks[i].start, greaterThanOrEqualTo(chunks[i - 1].end),
          reason: '第 $i 片与上一片重叠了');
    }
  }

  /// 片界不许落在不可拆散单元内部。
  ///
  /// 这里不按内容猜（猜漏一处就漏一个真 bug），而是**从原文重建**一张
  /// "哪些位置属于某个原子单元"的表：围栏代码块、连续表格行、连续引用行、
  /// 连续列表项的正文一律连成一段，只有整段的首尾才是合法切点。
  /// 表里为 true 却当了片界 → 说明这个原子单元被从中间劈开了。
  void expectNoMidUnitSplit(String content, List<NoteChunk> chunks) {
    bool blank(String line) => line.trim().isEmpty;
    bool fence(String line) {
      final t = line.trim();
      return t.startsWith('```') || t.startsWith('~~~');
    }

    bool startsList(String line) {
      var i = 0;
      while (i < line.length && line[i] == ' ') {
        i++;
      }
      if (i >= line.length) return false;
      final ch = line[i];
      if (ch == '-' || ch == '*' || ch == '+') {
        return i + 1 >= line.length || line[i + 1] == ' ';
      }
      final u = ch.codeUnitAt(0);
      if (u >= 0x30 && u <= 0x39) {
        var j = i;
        while (j < line.length &&
            line[j].codeUnitAt(0) >= 0x30 &&
            line[j].codeUnitAt(0) <= 0x39) {
          j++;
        }
        if (j - i <= 9 && j < line.length && (line[j] == '.' || line[j] == ')')) {
          return j + 1 >= line.length || line[j + 1] == ' ';
        }
      }
      return false;
    }

    final glue = List<bool>.filled(content.length, false);
    // 每个"连片区"：起点、终点、是不是只有一行
    final regions = <({int start, int end, bool inline})>[];
    var pos = 0;
    var inFence = false;
    var groupStart = -1;
    var groupEnd = -1;
    var groupKind = '';
    var prevBlank = true;

    void closeGroup() {
      for (var i = groupStart + 1; i < groupEnd; i++) {
        glue[i] = true;
      }
      regions.add((
        start: groupStart,
        end: groupEnd,
        inline: !content.substring(groupStart, groupEnd).contains('\n'),
      ));
      groupStart = -1;
      groupEnd = -1;
      groupKind = '';
    }

    for (final line in content.split('\n')) {
      final s = pos;
      // 行尾若有 \r，它属于这一行，不算进"内容"
      final e = line.endsWith('\r') ? pos + line.length - 1 : pos + line.length;
      pos += line.length + 1;

      String kind;
      if (inFence) {
        kind = 'fence';
        if (fence(line)) inFence = false;
      } else if (fence(line)) {
        kind = 'fence';
        inFence = true;
      } else if (blank(line)) {
        kind = '';
      } else if (startsList(line)) {
        kind = 'list';
      } else if (line.startsWith('|')) {
        kind = 'table';
      } else if (line.startsWith('>')) {
        kind = 'quote';
      } else {
        kind = 'text';
      }

      if (kind.isEmpty) {
        // 空行：代码块/表格/引用/列表允许跨空行连着；普通段落之间就此断开
        if (groupKind == 'text') closeGroup();
        prevBlank = true;
        continue;
      }

      final sameGroup = groupStart >= 0 &&
          (groupKind == 'fence' && kind == 'fence' ||
              groupKind == 'list' && kind == 'list' ||
              groupKind == 'table' && kind == 'table' ||
              groupKind == 'quote' && kind == 'quote' ||
              groupKind == 'text' && kind == 'text' && !prevBlank);
      if (sameGroup) {
        groupEnd = e;
      } else {
        if (groupStart >= 0) closeGroup();
        groupStart = s;
        groupEnd = e;
        groupKind = kind;
      }
      prevBlank = false;
    }
    if (groupStart >= 0) closeGroup();

    for (final c in chunks) {
      for (final at in [c.start, c.end]) {
        if (at >= glue.length) continue; // 文末之后没有"内部"
        if (!glue[at]) continue; // 落在原子单元之间的空隙 → 正常
        // 落在连片区内部：只有"这一片本身只有一行、且没有任何切得动的地方"
        // （例如一整段没有一个标点的超长文本）才允许——那不切就没法成片。
        final owner = regions.firstWhere((r) => at > r.start && at < r.end);
        if (owner.inline) continue;
        // **超过硬顶的原子单元必须拆**：一片超过 atomicCeiling，AI 根本读不进来
        // （`readChunk` 单次预算 1500 字），那它作为"片"就没意义了。
        // 所以这种单元内部的切点是**允许**的；硬顶以内的才不许碰。
        if (owner.end - owner.start > NoteChunker.atomicCeiling) continue;
        fail('片界落在了不可拆散单元内部（位置 $at，'
            '区间 ${owner.start}..${owner.end}）');
      }
    }
  }

  /// 常规用例的通用断言。
  void expectSound(String content, List<NoteChunk> chunks) {
    expectOrdered(content, chunks);
    expectNoContentLoss(content, chunks);
    expectNoMidUnitSplit(content, chunks);
  }

  // ==========================================================================
  // 空与短
  // ==========================================================================

  group('PROBE', () {
    test('probe nested', () {
      final text = '# 工作\n\n工作正文。${'甲' * 400}\n\n'
          '## 项目A\n\n项目正文。${'乙' * 400}\n\n'
          '### 风险\n\n风险正文。${'丙' * 400}';
      // 复刻 _lineStart 的算法，看它到底认为哪些位置是行首
      List<int> lineStart(String c, int from, int to) {
        final out = <int>[];
        var i = from;
        while (i < to) {
          out.add(i);
          var e = i;
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

      // ignore: avoid_print
      print('PROBE_LINE_STARTS=${lineStart(text, 0, text.length)}');
      // ignore: avoid_print
      print('PROBE_AT_411="${text.substring(411, 425).replaceAll('\n', '|')}"');
      // ignore: avoid_print
      print('PROBE_AT_417="${text.substring(417, 431).replaceAll('\n', '|')}"');
      // ignore: avoid_print
      print('PROBE_AT_420="${text.substring(420, 434).replaceAll('\n', '|')}"');
      final chunks = NoteChunker.chunk(text);
      for (final c in chunks) {
        // ignore: avoid_print
        print('PROBE ${c.start}..${c.end} len=${c.charCount} '
            'level=${c.level} heading="${c.heading}" '
            'head="${c.textOf(text).substring(0, 12).replaceAll('\n', '|')}"');
      }
    });
  });

  group('空与短', () {
    test('空正文返回空列表（调用方据此跳过这篇笔记）', () {
      expect(NoteChunker.chunk(''), isEmpty);
      expect(NoteChunker.chunk('   \n\n  '), isEmpty);
      expect(NoteChunker.chunk('\n\r\n'), isEmpty);
    });

    test('短笔记（不超过 shortNoteLimit）整篇一片', () {
      final short = '这是一段很短的笔记正文。' * 10; // 约 120 字
      expect(short.length, lessThanOrEqualTo(NoteChunker.shortNoteLimit));

      final chunks = NoteChunker.chunk(short);
      expect(chunks, hasLength(1));
      expect(chunks.single.start, 0);
      expect(chunks.single.end, short.length);
      expect(chunks.single.textOf(short), short);
      expect(chunks.single.heading, '');
      expect(chunks.single.level, 0);
    });

    test('正好等于上限也是一片', () {
      final text = 'a' * NoteChunker.cap;
      final chunks = NoteChunker.chunk(text);
      expect(chunks, hasLength(1));
      expect(chunks.single.charCount, NoteChunker.cap);
      expect(chunks.single.textOf(text), text);
      expectSound(text, chunks);
    });

    test('超过上限一个字符就得切', () {
      final text = 'a' * (NoteChunker.cap + 1);
      final chunks = NoteChunker.chunk(text);
      expect(chunks.length, greaterThan(1));
      expectSound(text, chunks);
    });
  });

  // ==========================================================================
  // 分层：标题 / level / 偏移
  // ==========================================================================

  group('分层：heading 路径与 level', () {
    test('多级标题嵌套 → heading 是完整路径，level 是最浅那一级', () {
      final text = '# 工作\n\n工作正文。${'甲' * 400}\n\n'
          '## 项目A\n\n项目正文。${'乙' * 400}\n\n'
          '### 风险\n\n风险正文。${'丙' * 400}';

      final chunks = NoteChunker.chunk(text);
      // 三节各约 410 字，都不到 cap(700) → **一节一片**，不用再拆。
      // （早先这里写 6，是把"每节还要分成标题片 + 正文片"当成了前提；
      //  实际上标题与它的正文**同一片**，而且 410 < 700 没有拆的理由。）
      expect(chunks.length, 3, reason: '三节各一片');
      expect(chunks[0].heading, '工作');
      expect(chunks[0].level, 1);
      expect(chunks[1].heading, '工作 / 项目A');
      expect(chunks[1].level, 2);
      expect(chunks[2].heading, '工作 / 项目A / 风险');
      expect(chunks[2].level, 3);
      expectSound(text, chunks);
    });

    test('遇到更高级的标题，更深层的遗留必须丢掉', () {
      // `## B` 是 `# A` 的子节；回到 `# C` 之后路径要重置成 `C`
      final text = '# A\n\nA 的正文。${'一' * 700}\n\n'
          '## B\n\nB 的正文。${'二' * 700}\n\n'
          '# C\n\nC 的正文。${'三' * 700}';

      final chunks = NoteChunker.chunk(text);
      final underC = chunks.where((x) => x.heading == 'C').toList();
      expect(underC, isNotEmpty, reason: 'C 下面那节必须存在');
      for (final x in underC) {
        expect(x.level, 1);
      }
      // ⚠️ 断言必须**限定在 C 之后的区域**：`A / B` 对 `## B` 那一节是**正确**的
      // 路径，全局搜它当然搜得到。早先写成全局 `isEmpty`，等于要求 B 自己也没有
      // 路径，与"更深标题归自己的路径"直接冲突。
      final cAt = text.indexOf('# C');
      expect(
        chunks.where((x) => x.start >= cAt && x.heading.contains('A / B')),
        isEmpty,
        reason: 'A / B 只在 ## B 那一节生效，不该出现在 C 下面',
      );
      expectSound(text, chunks);
    });

    test('更深标题出现时，它归自己的路径，不跟在上一节后面', () {
      // 目录节超 cap（否则它整段一片、根本不会递归到更深层）
      final text = '# 目录\n\n${'前面的话。' * 200}\n\n'
          '## 子标题\n\n子标题正文。${'丙' * 400}';

      final chunks = NoteChunker.chunk(text);
      final sub = chunks.where((x) => x.textOf(text).contains('## 子标题')).toList();
      expect(sub, isNotEmpty, reason: '子标题必须单独成片（好带上自己的路径）');
      for (final x in sub) {
        expect(x.heading, '目录 / 子标题');
        expect(x.level, 2);
      }
      for (final x in chunks.where((x) => x.end <= text.indexOf('## 子标题'))) {
        expect(x.heading, '目录', reason: '子标题之前的正文属于「目录」这一节');
        expect(x.level, 1);
      }
      expectSound(text, chunks);
    });

    test('不在任何标题下 → heading 为空、level 为 0', () {
      final text = '这是没有标题的正文。' * 120; // 远超 cap
      final chunks = NoteChunker.chunk(text);
      expect(chunks.length, greaterThan(1));
      for (final c in chunks) {
        expect(c.heading, '');
        expect(c.level, 0);
      }
      expectSound(text, chunks);
    });

    test('第一个标题之前的内容 heading 为空、level 为 0', () {
      final text = '${'开场白。' * 40}\n\n# 后面的标题\n\n${'正文。' * 40}';
      final chunks = NoteChunker.chunk(text);
      expect(chunks.first.heading, '', reason: '第一片来自标题之前');
      expect(chunks.first.level, 0);
      final underHead = chunks.where((c) => c.heading == '后面的标题');
      expect(underHead, isNotEmpty);
      for (final c in underHead) {
        expect(c.level, 1);
      }
      expectSound(text, chunks);
    });

    test('深节（#### ）的 level 是 4', () {
      final text = '#### deep\n\n${'a' * 200}';
      final chunks = NoteChunker.chunk(text);
      expect(chunks, hasLength(1));
      expect(chunks.single.textOf(text).startsWith('#### deep'), isTrue);
      expect(chunks.single.level, 4);
      expect(chunks.single.heading, 'deep');
    });

    test('带缩进的标题也算标题（level 以 # 的个数为准）', () {
      final text = '   ## 缩进标题\n\n${'内容。' * 200}';
      final chunks = NoteChunker.chunk(text);
      expect(chunks.first.heading, '缩进标题');
      expect(chunks.first.level, 2);
      expectSound(text, chunks);
    });
  });

  // ==========================================================================
  // 偏移
  // ==========================================================================

  group('偏移', () {
    test('每片的 textOf 逐字等于原文那段', () {
      final text = '# 标题\n\n第一段。${'甲' * 500}\n\n'
          '## 子标题\n\n第二段。${'乙' * 900}\n\n'
          '> 引用行 1\n> 引用行 2\n\n'
          '- 列表项一\n- 列表项二\n\n'
          '结尾一段。${'丙' * 300}';
      final chunks = NoteChunker.chunk(text);
      expect(chunks.length, greaterThan(1));
      expectOffsetsExact(text, chunks);
      expectNoContentLoss(text, chunks);
    });

    test('charCount == end - start', () {
      final text = '一句话。' * 300;
      for (final c in NoteChunker.chunk(text)) {
        expect(c.charCount, c.end - c.start);
      }
    });

    test('CRLF 文本：片与原文逐字相同，也不多出一个空行', () {
      final lf = List.generate(20, (i) => '第$i段。${'内容' * 28}').join('\n\n');
      final content = lf.replaceAll('\n', '\r\n');

      final chunks = NoteChunker.chunk(content);
      expect(chunks.length, greaterThan(1));
      expectSound(content, chunks);
      for (final c in chunks) {
        final t = c.textOf(content);
        expect(t, content.substring(c.start, c.end));
        // `\r` 属于上一行，不该被当成换行符导致空行翻倍
        expect(t.contains('\n\n\n'), isFalse);
        expect(t.contains('\r\r'), isFalse);
      }
    });

    test('硬切（无标点的超长文本）也不许把片界落在字中间', () {
      final text = 'a' * 2000;
      final chunks = NoteChunker.chunk(text);
      expectSound(text, chunks);
      for (final c in chunks) {
        expect(c.textOf(text), 'a' * c.charCount);
      }
    });
  });

  // ==========================================================================
  // 多段落长文
  // ==========================================================================

  group('多段落长文：片大小落在合理区间', () {
    /// 20 段，每段 46 字，段间空行 → 远超一片
    String manyParagraphs() =>
        List.generate(20, (i) => '第$i段。${'内容' * 28}').join('\n\n');

    test('能切出多片，不是一整篇', () {
      final chunks = NoteChunker.chunk(manyParagraphs());
      expect(chunks.length, greaterThan(1),
          reason: '长文必须切成多片，否则等于没切');
    });

    test('不含不可拆散单元的片一律不超过 cap', () {
      final text = manyParagraphs();
      for (final c in NoteChunker.chunk(text)) {
        expect(c.charCount, lessThanOrEqualTo(NoteChunker.cap),
            reason: '片太大 AI 又会去概括：${c.charCount} 字');
      }
    });

    test('除最后一片外都达到 floor 附近（不是碎块）', () {
      final chunks = NoteChunker.chunk(manyParagraphs());
      for (var i = 0; i < chunks.length - 1; i++) {
        expect(chunks[i].charCount, greaterThanOrEqualTo(NoteChunker.floor),
            reason: '第 $i 片只有 ${chunks[i].charCount} 字，太碎');
      }
    });

    test('不丢内容：去掉空白后逐字相等，每段标记都还在', () {
      final text = manyParagraphs();
      final chunks = NoteChunker.chunk(text);
      expectNoContentLoss(text, chunks);
      final joined = chunks.map((c) => c.textOf(text)).join();
      for (var i = 0; i < 20; i++) {
        expect(joined.contains('第$i段'), isTrue, reason: '第 $i 段丢了');
      }
    });
  });

  // ==========================================================================
  // 超长单段
  // ==========================================================================

  group('超长单段：按句子拆，不硬切', () {
    /// 一段 1000 字、每句 20 字、**没有空行**
    String oneBigParagraph() =>
        List.generate(50, (i) => '这是第$i个句子，说了一件事。').join();

    test('能切开', () {
      final chunks = NoteChunker.chunk(oneBigParagraph());
      expect(chunks.length, greaterThan(1));
    });

    test('每片不超过 cap', () {
      final text = oneBigParagraph();
      for (final c in NoteChunker.chunk(text)) {
        expect(c.charCount, lessThanOrEqualTo(NoteChunker.cap));
      }
    });

    test('尽量在句末断开，而不是从句子中间劈开', () {
      final text = oneBigParagraph();
      final chunks = NoteChunker.chunk(text);
      for (var i = 0; i < chunks.length - 1; i++) {
        final t = chunks[i].textOf(text);
        expect(t.endsWith('。'), isTrue,
            reason: '第 $i 片结尾是「${t.substring(t.length - 8)}」，没有断在句末');
      }
    });

    test('同段拆出的片段偏移连续（或只差空白），不凭空插空行', () {
      final text = oneBigParagraph();
      final chunks = NoteChunker.chunk(text);
      for (var i = 1; i < chunks.length; i++) {
        final between = text.substring(chunks[i - 1].end, chunks[i].start);
        expect(between.trim(), isEmpty,
            reason: '第 $i 片与上一片之间多出了非空白内容：「$between」');
      }
      for (final c in chunks) {
        expect(c.textOf(text).contains('\n'), isFalse,
            reason: '原文这段里没有换行，片里不该插入');
      }
    });
  });

  // ==========================================================================
  // 小片合并
  // ==========================================================================

  group('小片合并：顺序贪心', () {
    test('1400 字切成 7 个 200 字 → 必须是 600 / 600 / 200', () {
      // **切分单元必须正好 200 字**，否则算不出文档里那个 600/600/200：
      // 7 个 200 字的句子，填到上限时 3 个 = 600（第 4 个会到 800 > cap 700）。
      //
      // 早先这里用 20 字的句子造 1400 字，填到上限自然是 700（35 句）——
      // **那是输入造错了**（拿 20 字单元去套 200 字单元算出来的期望值），
      // 不是实现错。
      final text = List.generate(7, (i) => '${'甲' * 199}。').join();
      expect(text.length, 1400);

      final chunks = NoteChunker.chunk(text);
      expect(chunks.length, 3, reason: '必须合并成 3 片，而不是 7 片');
      expect(chunks[0].charCount, 600);
      expect(chunks[1].charCount, 600);
      expect(chunks[2].charCount, 200);
      expect(chunks[0].textOf(text), text.substring(0, 600));
      expect(chunks[1].textOf(text), text.substring(600, 1200));
      expect(chunks[2].textOf(text), text.substring(1200, 1400));
      // 600 + 200 = 800 > cap，所以第二片之后不能再并
      for (var i = 0; i < chunks.length - 1; i++) {
        expect(chunks[i].textOf(text).endsWith('。'), isTrue);
      }
      expectSound(text, chunks);
    });

    test('合并绝不越 cap：800 字只能是 700 + 100', () {
      final text = 'a' * 800;
      final chunks = NoteChunker.chunk(text);
      expect(chunks.map((c) => c.charCount).toList(), [700, 100]);
      expectSound(text, chunks);
    });

    test('尾片虽短也保留（不回头硬粘）', () {
      // 3 个 200 字的片（floor=300 → 并成一个 600）+ 200 字的尾巴
      final text = '${'a' * 199}。${'b' * 199}。${'c' * 199}。${'d' * 199}。';
      final chunks = NoteChunker.chunk(text);
      expect(chunks.map((c) => c.charCount).toList(), [600, 200]);
      expectSound(text, chunks);
    });

    test('并到 floor 就停手，不会一路并到底', () {
      // 十个 100 字的段：每 3 个并成 300（到 floor 就定稿），尾巴并进上一片
      final text = List.generate(10, (i) => '${'a' * 99}。').join('\n\n');
      final chunks = NoteChunker.chunk(text);
      expect(chunks.length, greaterThan(1), reason: '1000 字不该并成孤零零一片');
      for (final c in chunks) {
        expect(c.charCount, lessThanOrEqualTo(NoteChunker.cap));
        expect(c.charCount, greaterThanOrEqualTo(100));
      }
      expectSound(text, chunks);
    });
  });

  // ==========================================================================
  // Markdown 保护
  // ==========================================================================

  group('Markdown 保护：代码块 / 表格 / 引用 / 列表不拆散', () {
    // 48 行 × 约 16 字 ≈ 800 字 → 加上围栏行后**确实超过 cap(700)**，
    // 但离硬顶(1500)还远 —— 正好用来验证"不可拆散单元允许超 cap"。
    //
    // 早先用 40 行（约 670 字），实际**不到 cap**，于是"应当有一片超 cap"
    // 的前提根本不成立 —— 那是造数据时估错了长度。
    String fenceBody() => List.generate(48, (i) => 'line $i of code;').join('\n');

    test('围栏代码块整体留在同一片里（不超硬顶就不拆）', () {
      final text = '前面一段说明文字。\n\n'
          '```dart\n${fenceBody()}\n```\n\n'
          '后面一段说明文字。';

      final chunks = NoteChunker.chunk(text);
      final withFence =
          chunks.where((c) => c.textOf(text).contains('```')).toList();
      expect(withFence, hasLength(1),
          reason: '代码块被拆到多片里了——围栏必须完整在一片内');
      final t = withFence.single.textOf(text);
      expect('```'.allMatches(t).length, greaterThanOrEqualTo(2),
          reason: '同一片里要有开、合两个围栏');
      expect(t.contains('line 0 of code;'), isTrue);
      expect(t.contains('line 39 of code;'), isTrue);
      expectSound(text, chunks);
    });

    test('不可拆散单元允许超 cap（但仍在硬顶内）', () {
      // 代码块约 810 字 > cap(700)，但它是一个整体，不拆
      final text = '前言。\n\n```\n${fenceBody()}\n```\n\n后记。';
      final chunks = NoteChunker.chunk(text);
      final big = chunks.firstWhere((c) => c.charCount > NoteChunker.cap,
          orElse: () => chunks.first);
      expect(big.charCount, greaterThan(NoteChunker.cap),
          reason: '这一片应当允许超 cap');
      expect(big.charCount, lessThanOrEqualTo(NoteChunker.atomicCeiling));
      expect(big.textOf(text).contains('line 0 of code;'), isTrue);
      expect(big.textOf(text).contains('line 39 of code;'), isTrue);
      expectSound(text, chunks);
    });

    test('超过 atomicCeiling 的围栏代码块会被按行拆', () {
      // 每行 46 字 × 40 行 ≈ 1840 字 > 1500
      final long = List.generate(40, (i) => 'line $i: ${'x' * 35};').join('\n');
      final text = '```\n$long\n```';

      final chunks = NoteChunker.chunk(text);
      expect(chunks.length, greaterThan(1), reason: '超过硬顶就该拆了');
      for (final c in chunks) {
        expect(c.charCount, lessThanOrEqualTo(NoteChunker.atomicCeiling),
            reason: '超过 1500 的片 AI 读不进来');
      }
      expect(chunks.first.textOf(text).trimLeft().startsWith('```'), isTrue,
          reason: '开围栏要留在第一片开头（不能留下一个孤立的 ``` 单飞）');
      expect(chunks.last.textOf(text).trimRight().endsWith('```'), isTrue,
          reason: '合围栏要留在最后一片末尾');
      expectSound(text, chunks);
    });

    test('连续的表格行不被从中间切开', () {
      final rows = List.generate(30, (i) => '| 行$i | 值$i |').join('\n');
      final text = '表格说明。\n\n$rows\n\n表后说明。';

      final chunks = NoteChunker.chunk(text);
      final withTable =
          chunks.where((c) => c.textOf(text).contains('| 行0 |')).single;
      expect(withTable.textOf(text).contains('| 行29 |'), isTrue,
          reason: '表格被拆开了——行 29 不在同一片里');
      expectSound(text, chunks);
    });

    test('超过硬顶的表格按行拆，但不从行中间劈开', () {
      // 每行 47 字 × 60 行 ≈ 2880 字
      final rows = List.generate(60, (i) => '| 第$i行 | ${'值' * 20} |').join('\n');
      final text = '$rows\n';

      final chunks = NoteChunker.chunk(text);
      expect(chunks.length, greaterThan(1));
      for (final c in chunks) {
        expect(c.charCount, lessThanOrEqualTo(NoteChunker.atomicCeiling));
        for (final line in c.textOf(text).split('\n')) {
          if (line.isEmpty) continue;
          expect(line.startsWith('|') && line.endsWith('|'), isTrue,
              reason: '这一行被劈开了：$line');
        }
      }
      expectSound(text, chunks);
    });

    test('连续的引用行不被切开', () {
      final quotes = List.generate(30, (i) => '> 引用第 $i 句').join('\n');
      final text = '引言。\n\n$quotes\n\n结束语。';

      final chunks = NoteChunker.chunk(text);
      final withQuote =
          chunks.where((c) => c.textOf(text).contains('引用第 0 句')).single;
      expect(withQuote.textOf(text).contains('引用第 29 句'), isTrue,
          reason: '引用块被拆开了');
      expectSound(text, chunks);
    });

    test('连续的列表项不被切开（也不会被空行误判成两段）', () {
      final items = List.generate(30, (i) => '- 列表项 $i：一条还算长的内容').join('\n\n');
      final text = '清单说明。\n\n$items\n\n收尾说明。';

      final chunks = NoteChunker.chunk(text);
      final withList =
          chunks.where((c) => c.textOf(text).contains('列表项 0')).single;
      final t = withList.textOf(text);
      expect(t.contains('列表项 29'), isTrue,
          reason: '列表被拆开了：项之间空一行也还是同一个列表');
      expect(t.contains('列表项 15'), isTrue, reason: '中间的项丢了');
      expectSound(text, chunks);
    });

    test('超过硬顶的列表会被按行拆', () {
      // 每项约 71 字 × 40 项 ≈ 2870 字
      final items = List.generate(40, (i) => '- 第$i项，${'内容' * 34}').join('\n');
      final text = '开头。\n\n$items\n';

      final chunks = NoteChunker.chunk(text);
      expect(chunks.length, greaterThan(1), reason: '超过 1500 的列表必须拆');
      for (final c in chunks) {
        expect(c.charCount, lessThanOrEqualTo(NoteChunker.atomicCeiling));
      }
      // 判据是"**每一行都必须是原文里完整的一行**"，而不是"必须以 `- ` 开头"：
      // 第一片是那句 `开头。`（它不是列表项，本来就不以 `- ` 开头），
      // 用 `startsWith('- ')` 会把它误判成"列表项被劈开"。
      // 反过来，真被从中间劈开的行**不会等于任何原文行**，所以这个判据抓得住。
      final originalLines = text.split('\n').toSet();
      for (final c in chunks) {
        for (final line in c.textOf(text).split('\n')) {
          if (line.isEmpty) continue;
          expect(originalLines.contains(line), isTrue,
              reason: '列表项被从中间劈开了（这一行不是原文里的完整一行）：$line');
        }
      }
      expectSound(text, chunks);
    });
  });

  // ==========================================================================
  // 标题不孤立
  // ==========================================================================

  group('标题不孤立', () {
    test('标题与它下面的正文在同一片里', () {
      final body = '正文内容。' * 60;
      final text = '## 这是标题\n\n$body';

      final chunks = NoteChunker.chunk(text);
      final withTitle = chunks.where((c) => c.textOf(text).contains('## 这是标题'));
      expect(withTitle, hasLength(1));
      final t = withTitle.single.textOf(text);
      expect(t.startsWith('## 这是标题'), isTrue);
      expect(t.contains('正文内容'), isTrue);
      expect(t.length, greaterThan(NoteChunker.floor),
          reason: '标题所在片只有 ${t.length} 字，说明标题被孤立了');
      expectSound(text, chunks);
    });
  });

  // ==========================================================================
  // 保真
  // ==========================================================================

  group('保真', () {
    test('切出来的内容都来自原文（不含凭空生成的字）', () {
      final text = List.generate(15, (i) => '段落$i的内容在这里。').join('\n\n');
      for (final c in NoteChunker.chunk(text)) {
        expect(c.textOf(text), text.substring(c.start, c.end));
      }
    });

    test('首尾空白不进任何片（但内容一字不少）', () {
      final text = List.generate(15, (i) => '段落$i的内容在这里。').join('\n\n');
      final padded = '  \n\n$text\n\n  ';
      final chunks = NoteChunker.chunk(padded);
      expect(chunks, isNotEmpty);
      for (final c in chunks) {
        final t = c.textOf(padded);
        expect(t.startsWith(' '), isFalse, reason: '首部空白进了片');
        expect(t.endsWith(' '), isFalse, reason: '尾部空白进了片');
        expect(t.endsWith('\n'), isFalse, reason: '尾部空行进片');
      }
      expectSound(padded, chunks);
    });

    test('contentHash 与 NoteChunk.hashOf 一致', () {
      final text = '内容。' * 300;
      for (final c in NoteChunker.chunk(text)) {
        expect(c.contentHash, NoteChunk.hashOf(text, c.start, c.end));
      }
    });
  });

  // ==========================================================================
  // 稳定性 / 可区分
  // ==========================================================================

  group('片序稳定、片可区分', () {
    test('同一输入切两次，结果完全一致', () {
      final text =
          '# 标题\n\n${'内容。' * 200}\n\n- 列表\n- 列表二\n\n```\ncode\n```';
      final a = NoteChunker.chunk(text);
      final b = NoteChunker.chunk(text);
      expect(a.length, b.length);
      for (var i = 0; i < a.length; i++) {
        expect(a[i].start, b[i].start);
        expect(a[i].end, b[i].end);
        expect(a[i].heading, b[i].heading);
        expect(a[i].level, b[i].level);
        expect(a[i].contentHash, b[i].contentHash);
        expect(a[i].index, i);
      }
    });

    test('片数 > 1 时，能选到不同的片', () {
      final text = List.generate(30, (i) => '段落$i。${'内容' * 30}').join('\n\n');
      final chunks = NoteChunker.chunk(text);
      expect(chunks.length, greaterThan(1),
          reason: '只有一片的话，同一篇笔记抽两次必然给同一片');

      final contents = chunks.map((c) => c.textOf(text)).toSet();
      expect(contents.length, greaterThan(1), reason: '不同下标的片必须真的不同');
    });
  });
}
