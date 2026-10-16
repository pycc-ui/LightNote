// **RAG 到底值不值得做** —— 拿数字说话，不靠感觉。
//
// 这个文件不验证代码正确性，它回答一个产品问题：**加了语义检索之后，找得到的东西
// 变多了吗？同时是不是放进来一堆不该有的？**
//
// ## 为什么必须两路都测
//
// 我们已经有关键词检索（`SearchService`，LIKE）。所以"RAG 的收益"**不是**"能不能
// 搜到"，而是"**比关键词多找到多少**"。只测向量那一路好看没有意义 —— 必须三条线
// 并排比：
//
//   关键词（现状） / 语义（新） / 融合（要上线的）
//
// ## 评测设计（先把预测写下来，免得看到数字再编解释）
//
// 语料 20 篇：按"一个普通人真会记的笔记"写，每篇 500~900 字（会切成 2~3 片）。
// 查询 20 条，其中：
//   · **15 条有标准答案**（我知道哪一篇/哪几篇该被找到）
//   · **5 条本来就该无结果**（比如"如何养蜂"）—— 用来量误报
//
// ⚠️ 诚实的边界：**标注是我自己写的**，不是独立标注，所以这套数字只能说明
// "有没有明显问题"，不能当权威结论。真正的证据是那些"关键词字面必然搜不到"的
// 条目（下面标了 `gap:`）—— 那些不依赖我的主观判断。
//
// 跑法：`tool/test.sh test/rag_eval_test.dart -r expanded`
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lightnote/core/db/app_database.dart';
import 'package:lightnote/core/util/app_params.dart';
import 'package:lightnote/features/ai/data/rag_indexer.dart';
import 'package:lightnote/features/ai/domain/note_retriever.dart';
import 'package:lightnote/features/note/data/note_repository.dart';

import 'ort_gate.dart';

/// 一条评测查询。
class _Case {
  const _Case(this.query, this.expect, {this.gap = false, this.why});

  final String query;

  /// 标准答案：语料里的下标（空 = 这条本来就该无结果）。
  final List<int> expect;

  /// 这一条是不是"关键词字面必然搜不到"（靠字面判断，不靠我的主观）。
  final bool gap;

  /// 记一句为什么它是相关的。
  final String? why;
}

void main() {
  // 语料：20 篇真会记的笔记。
  //
  // 每一篇都刻意写成"有标题、有正文、长度够切成 2~3 片"，
  // 因为检索的粒度是**片**不是篇。
  final corpus = <String, String>{
    '周一 · 项目A 启动会': '''
# 参会
张伟、李娜、王强、我

# 目标
本季度把结算模块推到 3 个部门试点，6 月底交验收报告。
先把试点范围定成 2 个部门，第三个等第一轮反馈再定。

# 分工
张伟负责接口文档，李娜跟客户对验收标准，王强搭测试环境。
我盯整体进度，每周五更新一次风险清单。

# 风险
测试环境不稳定，上周挂了两次。李娜下周请假三天，验收标准的对齐会往后挪。
''',
    '项目B 周会纪要': '''
# 进展
登录改版做完了，灰度到 5%。埋点数据要等下周一才齐。

# 待办
把首页那几个入口的点击率拉出来对比。老代码里的兼容分支准备下掉，
影响范围要评估清楚再动，别把老用户的路径弄断了。

# 分歧
产品想这周就全量，技术觉得要再灰度一周。先按技术的意见来。
''',
    '季度考核自评': '''
# 做成的
结算模块从 0 到 1 上线，三个部门在用。把发布流程从手工改成自动，平均省两小时。

# 没做成的
原计划补的单元测试只写了一半。跨团队的那件事推进得很慢，对方没排期。

# 下季度
把测试覆盖率提到 60% 以上。把发布这件事彻底从我的日常里拿掉。
''',
    '报销流程备忘': '''
# 步骤
先在系统里填单，把发票拍照传上去。金额超过 2000 的要部门负责人先批。
纸质发票攒够一个月交一次给行政，别一张一张送。

# 坑
发票抬头写错的话要重开，来回三天。差旅的住宿标准每个城市不一样，
出差前先查一下，超了的部分自己承担。
''',
    '读《深度工作》的笔记': '''
# 核心观点
把不需要动脑的事集中到一块时间做完，留出连续的几小时给真正难的事。
被打断一次，回到原来的状态平均要十几分钟。

# 我的做法
上午九点到十一点不看任何消息。下午集中处理沟通类的事。
把手机放到另一个房间，比静音有用得多。

# 不同意的
他说社交网络基本没有价值，这个太绝对了。对做内容的人来说不是这样。
''',
    '健身计划（第三周）': '''
# 每周安排
周一推、周三拉、周五腿。每次四十分钟，最后十分钟做有氧。

# 记录
卧推从 40 加到 45，能做完 5 组了。深蹲还是不敢加，膝盖有点响。
引体向上还是只能做 3 个，先练辅助的。

# 吃
早饭加两个蛋。训练日晚上多吃一碗饭。体重没变，但腰围小了两厘米。
''',
    '给妈妈挑生日礼物': '''
# 想到的
她念叨过想换个轻一点的锅。也说过肩颈不舒服，按摩仪可能有用。
上次回家看她用的还是那个旧保温杯，盖子都松了。

# 不合适的
衣服不好买，尺码一直变。保健品她不信这些，买了也是放着。

# 定了
买个好点的锅，再配一个按摩仪。预算一千以内。
''',
    '十一家庭旅行计划': '''
# 目的地
本来想去海边，但十一人太多。改成去山里住几天，找个能看星星的地方。

# 要订的
民宿先订，带厨房的那种。高铁票开售当天早上抢，别拖到晚上。
租车提前一周，十一当天取车要排很久。

# 带什么
小孩的常用药、驱蚊的、薄外套（山里晚上冷）。
''',
    'Flutter 状态管理的几个坑': '''
# 重建范围
把整棵子树包在监听里是最常见的错误，一个字段变了整页重建。
要拆成小的监听单元，谁用谁听。

# 生命周期
在 build 里创建 controller 会在每次重建时新建一个，旧的没人释放。
要放在 State 里，或者用能自动回收的方式管理。

# 列表性能
长列表一定要用能复用的构建方式，不然滚动时内存一直涨。
itemExtent 能给的话一定给，能省掉大量布局计算。
''',
    'SQLite 查询变慢的排查': '''
# 症状
笔记表到两万行之后，按标题模糊查要几百毫秒，列表滚动时明显卡。

# 查到什么
没建索引，每次都是全表扫。LIKE 前面带通配符的话索引用不上，
这种情况要么换成前缀匹配，要么另建一张专门给搜索用的表。

# 怎么解
先给常用的排序列加索引。把大字段（正文）和列表要用的字段分开存，
列表查询就不要把正文一起读出来 —— 这一步立竿见影。
''',
    '咖啡豆怎么挑': '''
# 烘焙度
浅烘偏酸，有果味，适合手冲。深烘偏苦，油脂多，做意式更合适。
中烘是大多数人的安全选择。

# 新鲜度
看烘焙日期，不要看保质期。两周内喝完最好，放久了香气全没了。
别一次买太多，买小包装。

# 器具
手冲要磨得粗一点，意式要细。同一个豆子换个磨的程度，味道差很多。
''',
    '装修预算（还在改）': '''
# 已定
水电改造一万二。地板和瓷砖加起来两万。柜子找木工打，比定制便宜三成。

# 还没定
厨房要不要加洗碗机。阳台封不封，物业说不能改外立面。

# 超支了
原本预算十五万，现在看要十八万。主要超在人工上，师傅的报价和去年比涨了不少。
''',
    '英语学习计划': '''
# 现状
能看懂技术文档，但开口就卡。听力比阅读差很多，语速一快就跟不上。

# 计划
每天二十分钟听力，材料用播客，先听三遍再看原文。
每周找一次线上对话，哪怕只有半小时。

# 方法上的想法
背单词的收益到一定程度就没了，还是要靠大量输入。
把同一段材料反复听，比每天换新材料有用。
''',
    '面试题整理（算法）': '''
# 数组与字符串
两数之和用哈希表一遍过。最长无重复子串用滑动窗口。
这类题的关键是"用空间换时间"，先想能不能记住走过的。

# 链表
判断有环用快慢指针。反转用三个指针迭代，别写递归（栈会深）。

# 动态规划
先想状态是什么、怎么转移。背包问题要注意是"恰好装满"还是"不超过"，
这两种的初始值不一样，很容易写错。
''',
    '厨房收纳改造': '''
# 问题
台面永远堆满东西，柜子深处的东西拿不到，调料瓶找起来要翻半天。

# 改法
把常用的调料装进统一的瓶子，贴标签，放一层抽屉里。
锅具按大小叠放，加个架子分层。柜子深处放不常用的，前面放常用的。

# 效果
台面空出来一半。做饭的时候不用来回找东西了，快很多。
''',
    '车保养记录': '''
# 上次保养
四万公里，换了机油机滤，检查了刹车片（还有一半）。花了六百八。

# 待办
下次是四万五，主要换空调滤芯。轮胎快到年限了，虽然花纹还有，
但橡胶老化跑高速不放心，年底前换掉。

# 注意
保养灯亮了别拖太久。上次那个师傅说刹车油两年一换，我还没换过。
''',
    '保险配置的思路': '''
# 顺序
先给家里挣钱的人配。先保大事（生病、意外），再考虑理财型的。

# 买什么
医疗险和重疾险是基础。寿险只给有房贷的那一方买，额度覆盖贷款余额。
意外险便宜，加一份不亏。

# 不买什么
返还型的不划算，把保费拿去自己配置收益更好。
给孩子买寿险没意义，小孩不产生收入。
''',
    '拍照构图的几个习惯': '''
# 三分法
主体放在交叉点上，不要总放正中间。拍人的时候把眼睛放在上面那条线上。

# 光
顺光平，侧光有立体感，逆光要补光或者干脆拍剪影。
早上和傍晚的光最好，中午的光太硬。

# 简化
画面里能去掉的都去掉。实在去不掉就往近处走，用角度把它挡掉。
''',
    '最近睡眠不好': '''
# 情况
躺下要一个小时才睡着。半夜三四点会醒一次，醒了就很难再睡回去。
白天靠咖啡顶着，下午三点后喝的咖啡可能是原因。

# 试过的
睡前不看手机有点用，但坚持不下来。白噪音没用，反而更清醒。

# 想试的
把咖啡停掉两周看看。睡觉时间固定下来，哪怕周末也一样。
卧室温度调低一点，据说有帮助。
''',
    '记账三个月的心得': '''
# 发现
外卖花得比想象的多，一个月能有八九百。订阅类的服务有五个，其中两个基本没用。

# 改了什么
把没用的订阅退了。外卖限制在工作日中午，晚上自己做。
设了一个"想买的东西放购物车三天"的规矩，一半的东西三天后就不想买了。

# 结论
记账本身不省钱，看账才省。重点是找到那几个大头，不是记每一笔。
''',
  };

  // 20 条查询。`gap: true` = 关键词字面必然搜不到（这条不依赖我的主观）。
  const cases = <_Case>[
    // ---- 1~5：用词和原文对不上的（RAG 的主场，也是它的存在理由）----
    _Case('会议记录', [0], gap: true, why: '正文只有"参会/议题"，没有"会议"两个字'),
    _Case('怎么让大数据量查询不卡', [9], gap: true, why: '正文写的是"几百毫秒""全表扫"，没有"大数据量"'),
    _Case('睡不着怎么办', [18], gap: true, why: '标题是"最近睡眠不好"，正文没有"睡不着"'),
    _Case('如何提升专注力', [4], gap: true, why: '通篇讲"被打断""连续几小时"，没有"专注"二字'),
    _Case('想省钱有什么办法', [19], gap: true, why: '讲的是"记账""外卖""订阅"，没有"省钱"'),

    // ---- 6~10：换了种说法的（语义该赢，但关键词也可能沾上边）----
    _Case('给长辈送什么礼物', [6], why: '"妈妈""生日礼物" → 长辈送礼'),
    _Case('出去玩要准备什么', [7], why: '旅行计划里的"要订的/带什么"'),
    _Case('锻炼身体安排', [5], why: '"健身计划"的口语说法'),
    _Case('为什么我的页面很卡', [8], why: '性能与重建范围那几片'),
    _Case('装修要花多少钱', [11], why: '预算那篇，含"超支"'),

    // ---- 11~15：字面对得上的（关键词本来就该赢，用来确认没把老功能搞坏）----
    _Case('咖啡豆', [10]),
    _Case('保险', [16]),
    _Case('报销', [3]),
    _Case('算法面试', [13]),
    _Case('构图', [17]),

    // ---- 16~20：本来就该无结果（量误报）----
    _Case('如何养蜂', []),
    _Case('股票期权怎么估值', []),
    _Case('怎么修洗衣机', []),
    _Case('红酒的年份怎么看', []),
    _Case('登山的装备清单', []),
  ];

  group('RAG 离线评测', () {
    late AppDatabase db;
    late List<String> ids; // 与 corpus 顺序一致的笔记 id

    setUpAll(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      final notes = NoteRepository(db);

      ids = [];
      for (final entry in corpus.entries) {
        final n = await notes.createInbox(title: entry.key, content: entry.value);
        ids.add(n.id);
      }

      // 建索引：这是"用户装完 App 之后后台慢慢补"的那件事，评测里一次做完
      final indexer = RagIndexer(db);
      final indexed = await indexer.indexMissing(maxNotes: 100, budgetChunks: 500);
      // ignore: avoid_print
      print('▸ 语料 ${corpus.length} 篇 → 建了 $indexed 条向量');
      expect(indexed, greaterThan(0));
    });

    tearDownAll(() => db.close());

    test('★★ 自动注入只在"很确定"时才发生（不确定就什么都不给）', () async {
      // 这是产品决定，不是实现细节：宁可不给，也不给一条错的 —— 因为给错的
      // 那条模型没法自己发现，而少给的那条它还有工具能兜。
      final retriever = NoteRetriever(db);

      // ① 相关度很高的（实测 top1 = 0.664）→ 必须给
      final strong = await retriever.autoInjectBlock('睡不着怎么办');
      expect(strong, isNotNull, reason: '这条查询的相似度远高于注入线，应该给素材');
      expect(strong!, contains(kRetrievalMarker));
      expect(strong, contains('可能不相关'), reason: '必须说清这是猜的');
      expect(strong, contains('read_note_batch'), reason: '要告诉模型怎么接着读');
      expect(strong.length,
          lessThan(RagLimits.materialBudgetChars + 200),
          reason: '注入有硬预算，不能无限长');

      // ② 库里根本没有这个话题的（实测 top1 = 0.418 < 0.50）→ 必须不给
      final weak = await retriever.autoInjectBlock('如何养蜂');
      expect(weak, isNull, reason: '不确定就不要给 —— 这是 0.50 这条线的全部意义');

      // ③ 空查询不查
      expect(await retriever.autoInjectBlock('   '), isNull);
    }, skip: ortSkipReason);

    test('★★ 三路并排：关键词 / 语义 / 融合', () async {
      final retriever = NoteRetriever(db);

      // 每条查询在三路下的结果（把"哪几篇被找到"记下来，方便逐条看）
      final rows = <String>[];
      var kwHit = 0, vecHit = 0, fuseHit = 0;
      var kwGapHit = 0, vecGapHit = 0, fuseGapHit = 0;
      var gapTotal = 0;
      var kwFp = 0, vecFp = 0, fuseFp = 0;
      var negTotal = 0;
      var vecSpurious = 0; // 语义那一路返回了、但一条都不相关

      for (final c in cases) {
        final expectIds = {for (final i in c.expect) ids[i]};

        final kw = await retriever.byKeyword(c.query, limit: RagLimits.fusedTop);
        final vec = await retriever.byVector(c.query, limit: RagLimits.fusedTop);
        final fused = await retriever.retrieve(c.query);

        bool hitAny(List<RetrievedSnippet> r) =>
            r.any((s) => expectIds.contains(s.noteId));

        final isNeg = c.expect.isEmpty;
        if (isNeg) {
          negTotal++;
          if (kw.isNotEmpty) kwFp++;
          if (vec.isNotEmpty) vecFp++;
          if (fused.isNotEmpty) fuseFp++;
        } else {
          if (hitAny(kw)) kwHit++;
          if (hitAny(vec)) vecHit++;
          if (hitAny(fused)) fuseHit++;
          if (!hitAny(vec) && vec.isNotEmpty) vecSpurious++;
          if (c.gap) {
            gapTotal++;
            if (hitAny(kw)) kwGapHit++;
            if (hitAny(vec)) vecGapHit++;
            if (hitAny(fused)) fuseGapHit++;
          }
        }

        String mark(List<RetrievedSnippet> r) {
          if (r.isEmpty) return '—';
          return r
              .map((s) =>
                  '${_short(corpus.keys.elementAt(ids.indexOf(s.noteId)))}'
                  '${expectIds.contains(s.noteId) ? '✓' : '✗'}')
              .join(' ');
        }

        rows.add(
          '│ ${_pad(c.query, 24)} │ ${_pad(mark(kw), 30)} │ '
          '${_pad(mark(vec), 30)} │ ${_pad(mark(fused), 30)} │',
        );
      }

      final posTotal = cases.where((c) => c.expect.isNotEmpty).length;
      final buf = StringBuffer()
        ..writeln()
        ..writeln('  三路对比（✓ = 该找到的找到了，✗ = 找到的是错的，— = 什么都没找到）')
        ..writeln('  ┌${'─' * 26}┬${'─' * 32}┬${'─' * 32}┬${'─' * 32}┐')
        ..writeln('  │ ${_pad('查询', 24)} │ ${_pad('关键词（现状）', 30)} │ '
            '${_pad('语义（新）', 30)} │ ${_pad('融合（要上线）', 30)} │')
        ..writeln('  ├${'─' * 26}┼${'─' * 32}┼${'─' * 32}┼${'─' * 32}┤');
      for (final r in rows) {
        buf.writeln('  $r');
      }
      buf
        ..writeln('  └${'─' * 26}┴${'─' * 32}┴${'─' * 32}┴${'─' * 32}┘')
        ..writeln()
        ..writeln('  有答案的 $posTotal 条里，top-3 命中的条数：')
        ..writeln('    关键词 $kwHit / 语义 $vecHit / 融合 $fuseHit')
        ..writeln('  其中"字面必然搜不到"的 $gapTotal 条：'
            '关键词 $kwGapHit / 语义 $vecGapHit / 融合 $fuseGapHit'
            '  ← **这一行才是 RAG 的增量**')
        ..writeln('  语义召回了东西但一条都不相关的条数：$vecSpurious')
        ..writeln('  本该无结果的 $negTotal 条里，返回了东西的：'
            '关键词 $kwFp / 语义 $vecFp / 融合 $fuseFp  ← 误报');
      // ignore: avoid_print
      print(buf.toString());

      // ---- 第二条：及格线到底该定多少 ----
      //
      // 上面那张表暴露的问题：**语义永远能找出点什么**。要从 60 条候选里挑最大值，
      // 不相关的也会有一个冒到线上。所以"一条固定的绝对线"很可能根本不成立 ——
      // 这里把每条查询的分数分布打出来，直接看有没有可分的地方。
      final pos = <double>[]; // 有答案的查询：最高分
      final neg = <double>[]; // 无答案的查询：最高分
      final posGap = <double>[]; // 有答案的：最高分 - 全部分数的中位数
      final negGap = <double>[];
      final scoreRows = <String>[];

      for (final c in cases) {
        final sc = await retriever.rawVectorScores(c.query);
        if (sc.isEmpty) {
          scoreRows.add('│ ${_pad(c.query, 24)} │ （没有向量） │');
          continue;
        }
        final s1 = sc.first;
        final mid = sc[sc.length ~/ 2];
        final gap = s1 - mid;
        final over = sc.where((x) => x >= RagLimits.vectorMinScore).length;
        if (c.expect.isEmpty) {
          neg.add(s1);
          negGap.add(gap);
        } else {
          pos.add(s1);
          posGap.add(gap);
        }
        scoreRows.add(
          '│ ${_pad(c.query, 24)} │ ${_pad(s1.toStringAsFixed(3), 6)} │ '
          '${_pad(mid.toStringAsFixed(3), 6)} │ ${_pad(gap.toStringAsFixed(3), 6)} │ '
          '${_pad('$over', 6)} │ ${_pad(c.expect.isEmpty ? '无答案' : '有答案', 8)} │',
        );
      }

      // 扫一遍绝对线：看不同门槛下"漏掉的"和"误报的"各是多少
      final sweep = StringBuffer();
      for (final t in [0.35, 0.40, 0.45, 0.48, 0.50, 0.55]) {
        final miss = pos.where((x) => x < t).length;
        final fp = neg.where((x) => x >= t).length;
        sweep.writeln('    ${t.toStringAsFixed(2)}        '
            '${' ' * 6}$miss / ${pos.length}            $fp / ${neg.length}');
      }

      final sb = StringBuffer()
        ..writeln()
        ..writeln('  每条查询的分数分布（s1 = 最高分，mid = 全部分数的中位数）')
        ..writeln('  ┌${'─' * 26}┬${'─' * 8}┬${'─' * 8}┬${'─' * 8}┬${'─' * 8}┬${'─' * 10}┐')
        ..writeln('  │ ${_pad('查询', 24)} │ ${_pad('s1', 6)} │ ${_pad('mid', 6)} │ '
            '${_pad('落差', 6)} │ ${_pad('过线', 6)} │ ${_pad('有无答案', 8)} │')
        ..writeln('  ├${'─' * 26}┼${'─' * 8}┼${'─' * 8}┼${'─' * 8}┼${'─' * 8}┼${'─' * 10}┤');
      for (final r in scoreRows) {
        sb.writeln('  $r');
      }
      sb
        ..writeln('  └${'─' * 26}┴${'─' * 8}┴${'─' * 8}┴${'─' * 8}┴${'─' * 8}┴${'─' * 10}┘')
        ..writeln()
        ..writeln('  有答案 top1 最低 ${pos.reduce((a, b) => a < b ? a : b).toStringAsFixed(3)}'
            '，无答案 top1 最高 ${neg.reduce((a, b) => a > b ? a : b).toStringAsFixed(3)}')
        ..writeln('  → 两者重叠的话，**任何一条绝对线都分不开**')
        ..writeln()
        ..writeln('   绝对及格线   有答案的漏掉        无答案的误报')
        ..write(sweep)
        ..writeln()
        ..writeln('  相对判据（top1 比全库中位数高出多少）：')
        ..writeln('    有答案的落差 ${posGap.map((x) => x.toStringAsFixed(3)).toList()}'
            ' 最低 ${posGap.reduce((a, b) => a < b ? a : b).toStringAsFixed(3)}')
        ..writeln('    无答案的落差 ${negGap.map((x) => x.toStringAsFixed(3)).toList()}'
            ' 最高 ${negGap.reduce((a, b) => a > b ? a : b).toStringAsFixed(3)}');
      // ignore: avoid_print
      print(sb.toString());

      // ---- 断言：把实测到的水平钉住，防止以后悄悄退化 ----
      //
      // 数字都留了余量（实测 11/4/1，断言按 10/3/2 钉），因为这些是"语义质量"的
      // 指标，不是精确输出 —— 差一条不该让构建红，但掉一大截必须红。
      expect(fuseHit, greaterThanOrEqualTo(kwHit),
          reason: '融合之后不该比现在的关键词更差（实测 11 vs 4）');
      expect(fuseHit, greaterThanOrEqualTo(10),
          reason: '15 条有答案的查询，top-3 至少要找到 10 条（实测 11）');
      expect(fuseGapHit, greaterThanOrEqualTo(3),
          reason: '「字面必然搜不到」那 5 条至少要找到 3 条 —— '
              '这是 RAG 存在的唯一理由（实测 4；关键词是 0）');
      expect(fuseFp, lessThanOrEqualTo(2),
          reason: '5 条本该无结果的查询里最多误报 2 条（实测 1）—— '
              '及格线定在 0.45 就是为了这个');
    }, skip: ortSkipReason);
  });
}

String _pad(String s, int width) {
  // 中文按两格算，否则表格会歪
  var w = 0;
  for (final r in s.runes) {
    w += r > 0x2E80 ? 2 : 1;
  }
  if (w >= width) {
    // 太长的截断（按显示宽度估）
    var out = '';
    var acc = 0;
    for (final r in s.runes) {
      final cw = r > 0x2E80 ? 2 : 1;
      if (acc + cw > width - 1) break;
      out += String.fromCharCode(r);
      acc += cw;
    }
    return '$out…${' ' * (width - acc - 1)}';
  }
  return '$s${' ' * (width - w)}';
}

String _short(String title) {
  final t = title.replaceAll('（', '(').replaceAll('）', ')');
  return t.length <= 6 ? t : t.substring(0, 6);
}
