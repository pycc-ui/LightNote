// LogBar 行为测试。
//
// 这套测试的由来：用户报告「LogBar.action 弹出的提示不会自动消失」。
//
// 那个 bug **光读 log_bar.dart 看不出来**——那里明明写了 duration: 3 秒。
// 真正的开关在 Flutter 内部：
//
//     // snack_bar.dart
//     persist = persist ?? action != null;        // 有 action 就默认 true
//     // scaffold.dart
//     _snackBarTimer = Timer(snackBar.duration, () {
//       if (snackBar.persist) return;             // 直接返回，永不超时
//       hideCurrentSnackBar(reason: timeout);
//     });
//
// 所以：**传了 SnackBarAction ⇒ persist 默认 true ⇒ duration 被完全忽略**。
//
// 随后顺带排查出另外两个问题，也各有对应用例：
//   · busy 提示泄漏（close 写在了 `if (!mounted) return;` 之后）
//   · 任务进行中弹普通提示会堆积到任务结束后才播（过期刷屏）
//
// 写这类测试的两个坑（自己都踩过）：
//   · 时间要**分步推进**。pump(Duration(seconds: 4)) 只渲染一帧、
//     不让中途 Timer 触发，据此得出的结论会是错的。
//   · 点击前要等入场动画跑完，否则按钮透明度为 0，hit test 打不中。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_notes/core/widgets/log_bar.dart';

Widget _host() => const MaterialApp(home: Scaffold(body: SizedBox()));

/// 分步推进时间，让中途到期的 Timer 有机会跑。
Future<void> _advance(
  WidgetTester tester,
  Duration total, {
  Duration step = const Duration(milliseconds: 250),
}) async {
  var elapsed = Duration.zero;
  while (elapsed < total) {
    await tester.pump(step);
    elapsed += step;
  }
}

void main() {
  group('自动收起', () {
    testWidgets('info 自动消失', (tester) async {
      await tester.pumpWidget(_host());
      final ctx = tester.element(find.byType(Scaffold));

      LogBar.info(ctx, '普通提示');
      await tester.pump();
      expect(find.text('普通提示'), findsOneWidget);

      await _advance(tester, const Duration(seconds: 5));
      expect(find.text('普通提示'), findsNothing);
    });

    // 就是这条当初会挂：带 action 的 SnackBar 默认 persist，永不超时
    testWidgets('action 传 persist:false 时会自动消失（回归：曾被 persist 卡住）',
        (tester) async {
      await tester.pumpWidget(_host());
      final ctx = tester.element(find.byType(Scaffold));

      LogBar.action(ctx, '已加入「工作笔记」',
          actionLabel: '撤销', onAction: () {}, persist: false);

      await tester.pump();
      expect(find.text('已加入「工作笔记」'), findsOneWidget);

      await _advance(tester, const Duration(seconds: 5));
      expect(find.text('已加入「工作笔记」'), findsNothing);
    });

    testWidgets('success / error 自动消失', (tester) async {
      await tester.pumpWidget(_host());
      final ctx = tester.element(find.byType(Scaffold));

      LogBar.success(ctx, '已加入 3 张卡片');
      await tester.pump();
      expect(find.text('已加入 3 张卡片'), findsOneWidget);
      await _advance(tester, const Duration(seconds: 5));
      expect(find.text('已加入 3 张卡片'), findsNothing);

      LogBar.error(ctx, '发送失败');
      await tester.pump();
      expect(find.text('发送失败'), findsOneWidget);
      await _advance(tester, const Duration(seconds: 5));
      expect(find.text('发送失败'), findsNothing);
    });

    // warn 的时长比其他级别多 1 秒：这类消息用户需要看清"为什么没成"
    testWidgets('warn 自动消失（且比 info 多停 1 秒）', (tester) async {
      await tester.pumpWidget(_host());
      final ctx = tester.element(find.byType(Scaffold));

      LogBar.warn(ctx, '没能从这篇笔记生成卡片');
      await tester.pump();
      expect(find.text('没能从这篇笔记生成卡片'), findsOneWidget);

      // 3 秒时 info 早该走了，warn 应该还在
      await _advance(tester, const Duration(milliseconds: 3200));
      expect(find.text('没能从这篇笔记生成卡片'), findsOneWidget,
          reason: 'warn 应比 info 多停留一会儿');

      await _advance(tester, const Duration(seconds: 2));
      expect(find.text('没能从这篇笔记生成卡片'), findsNothing);
    });
  });

  group('action 的常驻策略', () {
    // 默认 persist: true —— 用于"旧数据留档在哪个路径"这类必须看清的内容
    testWidgets('默认常驻：action 不会自己消失', (tester) async {
      await tester.pumpWidget(_host());
      final ctx = tester.element(find.byType(Scaffold));

      LogBar.action(ctx, '已从备份恢复，旧数据已留档：D:\\backup',
          actionLabel: '知道了');

      await tester.pump();
      await _advance(tester, const Duration(seconds: 10));
      expect(find.textContaining('已从备份恢复'), findsOneWidget,
          reason: '读完之前不该消失，否则用户拿不到留档路径');
    });

    testWidgets('点 action 按钮会收起并执行回调', (tester) async {
      await tester.pumpWidget(_host());
      final ctx = tester.element(find.byType(Scaffold));
      var tapped = false;

      LogBar.action(ctx, '已加入「工作笔记」',
          actionLabel: '撤销', onAction: () => tapped = true);

      // 等入场动画跑完，否则按钮不可命中
      await _advance(tester, const Duration(milliseconds: 500));
      expect(find.text('撤销'), findsOneWidget);

      await tester.tap(find.text('撤销'));
      await _advance(tester, const Duration(seconds: 1));

      expect(tapped, isTrue);
      expect(find.text('已加入「工作笔记」'), findsNothing);
    });
  });

  group('busy', () {
    testWidgets('busy 拦住后续提示；close 后排队的那条按自己的时长消失',
        (tester) async {
      await tester.pumpWidget(_host());
      final ctx = tester.element(find.byType(Scaffold));

      final busy = LogBar.busy(ctx, '正在整理笔记…');
      await tester.pump();
      expect(find.text('正在整理笔记…'), findsOneWidget);
      expect(LogBar.isBusy, isTrue);

      // 任务期间的普通提示会被丢弃（见"过期提示"那组），
      // 所以这里用一个显式允许穿透的 action 来验证排队行为
      LogBar.action(ctx, '已加入「工作笔记」',
          actionLabel: '撤销', onAction: () {},
          persist: false,
          showWhileBusy: true);
      await _advance(tester, const Duration(seconds: 5));

      expect(find.text('正在整理笔记…'), findsOneWidget);
      expect(find.text('已加入「工作笔记」'), findsNothing, reason: '前一条没走完要排队');

      busy.close();
      expect(LogBar.isBusy, isFalse);
      await _advance(tester, const Duration(seconds: 1));
      expect(find.text('正在整理笔记…'), findsNothing);
      expect(find.text('已加入「工作笔记」'), findsOneWidget);

      // 从"自己显示出来"起算 3 秒，而不是从入队起算
      await _advance(tester, const Duration(seconds: 4));
      expect(find.text('已加入「工作笔记」'), findsNothing);
    });

    testWidgets('close 可以重复调用，不报错', (tester) async {
      await tester.pumpWidget(_host());
      final ctx = tester.element(find.byType(Scaffold));

      final busy = LogBar.busy(ctx, '正在处理…');
      await tester.pump();
      busy.close();
      busy.close(); // try/finally 里可能和别处的 close 重叠
      await _advance(tester, const Duration(seconds: 1));
      expect(find.text('正在处理…'), findsNothing);
      expect(LogBar.isBusy, isFalse);
    });
  });

  group('任务进行中的过期提示', () {
    // 这条对应一个真实体验问题：AI 整理要几十秒，期间用户再点几下，
    // 弹出若干提示全都堆在队列里，任务结束后才开始一条条播 ——
    // 用户看到的是一串已经没意义的提示在刷屏。
    testWidgets('busy 期间 info/success 被丢弃，不排队', (tester) async {
      await tester.pumpWidget(_host());
      final ctx = tester.element(find.byType(Scaffold));

      final busy = LogBar.busy(ctx, '正在生成卡片…');
      await tester.pump();

      LogBar.info(ctx, '正文为空');
      LogBar.success(ctx, '已复制全文');
      LogBar.info(ctx, '还没配置 API Key');
      await tester.pump();

      busy.close();
      await _advance(tester, const Duration(seconds: 5));

      expect(find.text('正文为空'), findsNothing, reason: '过期提示不该在任务后刷屏');
      expect(find.text('已复制全文'), findsNothing);
      expect(find.text('还没配置 API Key'), findsNothing);
    });

    // 失败信息反过来必须能穿透，否则用户只看到转圈不知道已经失败了
    testWidgets('busy 期间 error 仍然会显示', (tester) async {
      await tester.pumpWidget(_host());
      final ctx = tester.element(find.byType(Scaffold));

      final busy = LogBar.busy(ctx, '正在整理笔记…');
      await tester.pump();

      LogBar.error(ctx, '整理失败：连接超时');
      await tester.pump();

      // error 排在 busy 后面，先收起 busy 才能看到它
      busy.close();
      await _advance(tester, const Duration(seconds: 1));

      expect(find.text('整理失败：连接超时'), findsOneWidget,
          reason: '失败必须告知，不能因为"任务进行中"被丢掉');
    });

    testWidgets('没有 busy 时 info 正常显示', (tester) async {
      await tester.pumpWidget(_host());
      final ctx = tester.element(find.byType(Scaffold));

      LogBar.info(ctx, '没有任务时的提示');
      await tester.pump();
      expect(find.text('没有任务时的提示'), findsOneWidget);
    });
  });
}
