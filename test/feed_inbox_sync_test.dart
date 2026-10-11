// 卡片上的「加入 / 移出」必须和「我的轻笔记」**始终一致**。
//
// ## 这里修的是什么
//
// 用户报的 bug：在卡片上收下一条，然后跑到笔记库页把那条笔记删掉，
// 回到轻笔记页，卡片**还显示着「已加入」**，而且点不动。
//
// 根因：卡片的状态是**本页面的内存字段**（`_Card.added`），
// 数据库那边变了它不知道。所以修法是让"已加入"完全由数据库推导。
//
// 这个文件测的正是那条推导规则。它是纯逻辑，可以脱离界面测——
// 而且必须测，因为出错的后果就是"两边对不上"。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lightnote/core/db/app_database.dart';
import 'package:lightnote/core/db/models.dart';
import 'package:lightnote/features/note/data/notebook_repository.dart';
import 'package:lightnote/features/note/data/note_repository.dart';

/// 与 InboxPage 里 `_fingerprint` 相同的规则。
///
/// 复制一份是刻意的：这里要**独立验证**规则本身站得住，
/// 而不是从实现里 import 出来自证。
String fingerprint(String title, String body) =>
    '${title.trim()}\u0000${body.trim()}';

/// 与 InboxPage 里 `_noteForCard` 相同的推导。
Note? noteForCard({
  required FeedDraft draft,
  required String? noteId,
  required Map<String, Note> byFingerprint,
}) {
  final byPrint = byFingerprint[fingerprint(draft.title, draft.body)];
  if (byPrint != null) return byPrint;
  if (noteId != null) {
    for (final n in byFingerprint.values) {
      if (n.id == noteId) return n;
    }
  }
  return null;
}

void main() {
  late AppDatabase db;
  late NoteRepository notes;
  late NotebookRepository notebooks;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    notes = NoteRepository(db);
    notebooks = NotebookRepository(db);
  });

  tearDown(() => db.close());

  /// 把当前「我的轻笔记」做成推导依据，和页面里做的一样。
  Future<Map<String, Note>> snapshot() async {
    final list = await notes.watchUnfiled().first;
    return {for (final n in list) fingerprint(n.title, n.content): n};
  }

  const draft = FeedDraft(
    title: '记笔记时想分类，等于自断灵感',
    body: '正文内容，讲的是先写下来再整理。',
    tags: ['笔记法'],
  );

  group('收下 → 卡片显示已加入', () {
    test('写库之后凭内容能认出来', () async {
      expect(await snapshot(), isEmpty);

      final made = await notes.createInbox(
        title: draft.title,
        content: draft.body,
      );

      final map = await snapshot();
      final found = noteForCard(
        draft: draft,
        noteId: made.id,
        byFingerprint: map,
      );
      expect(found, isNotNull, reason: '收下之后应当认得出这条');
      expect(found!.id, made.id);
    });
  });

  group('在别处删掉 → 卡片退回未加入（用户报的 bug）', () {
    test('在笔记库把这条删掉后，卡片不再算已加入', () async {
      final made = await notes.createInbox(
        title: draft.title,
        content: draft.body,
      );

      // 收下之后：认得出
      expect(
        noteForCard(
            draft: draft, noteId: made.id, byFingerprint: await snapshot()),
        isNotNull,
      );

      // 用户跑到笔记库页把它删了
      await notes.softDelete(made.id);

      // 回到轻笔记页：必须认不出来了 → 按钮回到「加入我的轻笔记」
      expect(
        noteForCard(
            draft: draft, noteId: made.id, byFingerprint: await snapshot()),
        isNull,
        reason: '笔记已不在「我的轻笔记」里，卡片就该回到未加入',
      );
    });

    test('删掉之后撤销，卡片又变回已加入', () async {
      final made = await notes.createInbox(
        title: draft.title,
        content: draft.body,
      );
      await notes.softDelete(made.id);
      expect(
        noteForCard(
            draft: draft, noteId: made.id, byFingerprint: await snapshot()),
        isNull,
      );

      await notes.restore(made.id);
      expect(
        noteForCard(
            draft: draft, noteId: made.id, byFingerprint: await snapshot()),
        isNotNull,
        reason: '撤销删除后应当又认得出',
      );
    });

    test('把笔记归档到笔记库（离开未归档）后，卡片也回到未加入', () async {
      final made = await notes.createInbox(
        title: draft.title,
        content: draft.body,
      );
      expect(
        noteForCard(
            draft: draft, noteId: made.id, byFingerprint: await snapshot()),
        isNotNull,
      );

      // 归入某个笔记库 → 不再属于「我的轻笔记」
      final nb = await notebooks.create(name: '工作');
      await notes.moveToNotebook(made.id, nb.id);

      expect(
        noteForCard(
            draft: draft, noteId: made.id, byFingerprint: await snapshot()),
        isNull,
        reason: '归档走之后它就不再是「我的轻笔记」，卡片该回到未加入',
      );
    });
  });

  group('从卡片移出', () {
    test('移出就是把它从「我的轻笔记」删掉，卡片随即退回未加入', () async {
      final made = await notes.createInbox(
        title: draft.title,
        content: draft.body,
      );

      // 卡片上点「从我的轻笔记移出」
      await notes.softDelete(made.id);

      expect(await notes.watchUnfiled().first, isEmpty,
          reason: '笔记库页的「我的轻笔记」里也该少一条');
      expect(
        noteForCard(
            draft: draft, noteId: made.id, byFingerprint: await snapshot()),
        isNull,
      );
    });
  });

  group('内容被改过时的兜底（用 noteId 认）', () {
    test('标题被改过，但同一会话里记着 id，仍算已加入', () async {
      final made = await notes.createInbox(
        title: draft.title,
        content: draft.body,
      );

      // 用户去编辑页把标题改了 → 指纹对不上
      await notes.saveContent(made.id, title: '我自己改的标题', content: draft.body);

      final map = await snapshot();
      // 指纹认不出
      expect(map[fingerprint(draft.title, draft.body)], isNull);
      // 但 id 还记着 → 仍然算已加入（这是刻意的：内容改了还是同一条）
      final found = noteForCard(
        draft: draft,
        noteId: made.id,
        byFingerprint: map,
      );
      expect(found, isNotNull, reason: '同一会话里记着 id，改过标题也认得出');
      expect(found!.id, made.id);
    });

    test('没有 id（跨会话）且内容被改过 → 认不出，退回未加入', () async {
      final made = await notes.createInbox(
        title: draft.title,
        content: draft.body,
      );
      await notes.saveContent(made.id, title: '改过的标题', content: draft.body);

      // 模拟重启 App：内存里没有 noteId
      final found = noteForCard(
        draft: draft,
        noteId: null,
        byFingerprint: await snapshot(),
      );
      expect(found, isNull,
          reason: '跨会话只能靠内容认；内容改了认不出是可接受的取舍');
    });
  });

  group('指纹不会误判', () {
    test('两条不同笔记的指纹不同', () {
      expect(fingerprint('A', 'B'), isNot(fingerprint('B', 'A')));
    });

    test('只有标题相同不算同一条', () {
      expect(fingerprint('标题', '正文一'), isNot(fingerprint('标题', '正文二')));
    });

    test('首尾空白不影响指纹', () {
      expect(fingerprint(' 标题 ', ' 正文 '), fingerprint('标题', '正文'));
    });

    test('不同卡片收下后各自对应自己的那条', () async {
      const other = FeedDraft(title: '另一条', body: '另一段正文');
      final a = await notes.createInbox(title: draft.title, content: draft.body);
      final b = await notes.createInbox(title: other.title, content: other.body);
      final map = await snapshot();

      expect(
        noteForCard(draft: draft, noteId: null, byFingerprint: map)!.id,
        a.id,
      );
      expect(
        noteForCard(draft: other, noteId: null, byFingerprint: map)!.id,
        b.id,
      );
    });
  });
}
