// 阶段 2 的**界面接线**：阅读视图按片渲染、能定位到指定片、搜索页分两类。
//
// 为什么这些必须用 widget 测试：切片与搜索的**逻辑**已经在
// `note_chunker_test.dart` / `search_service_test.dart` 里测过了，但
// "渲染时真的按片拆成了多个 widget""传进去的片号真的滚起来了"
// 都是**布局之后**才成立的事，纯数据层测不出来。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:smart_notes/core/db/app_database.dart';
import 'package:smart_notes/core/prefs/preferences_service.dart';
import 'package:smart_notes/features/ai/data/deepseek_client.dart';
import 'package:smart_notes/features/ai/domain/ai_repository.dart';
import 'package:smart_notes/features/note/data/note_repository.dart';
import 'package:smart_notes/features/note/data/search_service.dart';
import 'package:smart_notes/features/note/domain/note_chunker.dart';
import 'package:smart_notes/features/note/ui/note_editor_page.dart';
import 'package:smart_notes/features/note/ui/search_page.dart';

void main() {
  late AppDatabase db;
  late NoteRepository notes;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    notes = NoteRepository(db);
  });
  tearDown(() => db.close());

  /// 三章、每章都够长 → 保证切成 3 片（每片 ≈420 字，不用再拆）
  String threeChapters() => '# 甲章\n\n${'甲的内容。' * 85}\n\n'
      '# 乙章\n\n${'乙的内容。' * 85}\n\n'
      '# 丙章\n\n${'丙的内容。' * 85}';

  Widget host(Widget child) {
    return MultiProvider(
      providers: [
        Provider<NoteRepository>.value(value: notes),
        Provider<PreferencesService>(create: (_) => PreferencesService(db)),
        Provider<SearchService>(create: (_) => SearchService(db)),
        Provider<AiRepository>(
          create: (_) => AiRepository(db: db, client: DeepSeekClient()),
        ),
      ],
      child: MaterialApp(home: child),
    );
  }

  group('阅读视图按片渲染', () {
    testWidgets('每片一个 Markdown widget，数量与切片器一致', (tester) async {
      final note = await notes.createInbox(title: '三章', content: threeChapters());
      final expected = NoteChunker.chunk(note.content).length;
      expect(expected, 3, reason: '这份测试数据本来就是为了切出 3 片');

      await tester.pumpWidget(host(
        NoteEditorPage(noteId: note.id, startInReading: true),
      ));
      await tester.pumpAndSettle();

      // 整篇一个 Markdown 的话这里只会是 1
      expect(find.byType(Markdown), findsNWidgets(expected));
    });

    testWidgets('空正文不炸，显示占位', (tester) async {
      final note = await notes.createInbox(title: '空', content: '');
      await tester.pumpWidget(host(
        NoteEditorPage(noteId: note.id, startInReading: true),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('正文为空'), findsOneWidget);
    });

    testWidgets('片正文与原文逐字一致（渲染的就是原文那几段）', (tester) async {
      final note = await notes.createInbox(title: '三章', content: threeChapters());
      final chunks = NoteChunker.chunk(note.content);

      await tester.pumpWidget(host(
        NoteEditorPage(noteId: note.id, startInReading: true),
      ));
      await tester.pumpAndSettle();

      final widgets = tester.widgetList<Markdown>(find.byType(Markdown)).toList();
      for (var i = 0; i < chunks.length; i++) {
        expect(widgets[i].data, chunks[i].textOf(note.content));
      }
    });

    testWidgets('给了 initialChunk 就滚下去（不是停在开头）', (tester) async {
      final note = await notes.createInbox(title: '三章', content: threeChapters());

      await tester.pumpWidget(host(
        NoteEditorPage(noteId: note.id, startInReading: true, initialChunk: 2),
      ));
      await tester.pumpAndSettle();

      final pos = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      expect(pos.pixels, greaterThan(0),
          reason: '定位到第 2 片却没滚动，等于没定位');
    });

    testWidgets('不给 initialChunk 就停在开头', (tester) async {
      final note = await notes.createInbox(title: '三章', content: threeChapters());

      await tester.pumpWidget(host(
        NoteEditorPage(noteId: note.id, startInReading: true),
      ));
      await tester.pumpAndSettle();

      final pos = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      expect(pos.pixels, 0);
    });
  });

  group('搜索页分两类', () {
    testWidgets('标题命中进「笔记」、正文命中进「笔记内容」', (tester) async {
      // 标题里有关键词，正文里也有关键词 —— 两类各一条
      await notes.createInbox(title: '番茄工作法', content: '无关正文。');
      await notes.createInbox(title: '我的笔记', content: '# 甲章\n\n这里提到番茄工作法。');

      await tester.pumpWidget(host(const SearchPage()));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '番茄');
      // 等防抖 250ms + future 落地
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(find.text('笔记（1）'), findsOneWidget);
      expect(find.text('笔记内容（1）'), findsOneWidget);
    });

    testWidgets('正文命中的那条显示小节名', (tester) async {
      await notes.createInbox(title: '我的笔记', content: '# 甲章\n\n这里提到番茄工作法。');

      await tester.pumpWidget(host(const SearchPage()));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '番茄');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      // 副标题「甲章」让用户知道命中在哪一节
      expect(find.text('甲章'), findsOneWidget);
    });

    testWidgets('搜不到时给空结果提示，不显示分类标题', (tester) async {
      await notes.createInbox(title: '无关', content: '平平无奇。');

      await tester.pumpWidget(host(const SearchPage()));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '绝无此词');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(find.textContaining('笔记（'), findsNothing);
      expect(find.textContaining('笔记内容（'), findsNothing);
    });
  });
}
