// 笔记篇幅上限的分档与裁剪。
//
// 之所以值得单独测：阈值边界（正好 30KB 算哪一档）最容易写错，
// 而写错的表现是"显示 50.0 KB 却还能保存"这种自相矛盾的提示。
import 'package:flutter_test/flutter_test.dart';

import 'package:lightnote/core/util/ai_limits.dart';

void main() {
  /// 造一段**恰好** [bytes] 字节的文本（用 ASCII，1 字节 1 字符）。
  String ascii(int bytes) => 'a' * bytes;

  /// 造一段**恰好** [bytes] 字节的中文文本（每字 3 字节）。
  ///
  /// 先放 `bytes ~/ 3` 个汉字，再用 ASCII 补齐余数——
  /// 直接 `bytes ~/ 3` 会少 1~2 字节，边界测试就会偏出档位
  /// （第一版这里写错过，正好软上限被判成了 ok）。
  String cjk(int bytes) {
    final full = bytes ~/ 3;
    final rest = bytes - full * 3;
    return ('字' * full) + ('a' * rest);
  }

  group('字节计数与阈值一致', () {
    test('AiLimits.byteLength 与 utf8ByteLength 一致', () {
      expect(AiLimits.byteLength('中文abc'), utf8ByteLength('中文abc'));
    });

    test('阈值换算成 KB 与文案一致', () {
      expect(AiLimits.noteSoftBytes ~/ 1024, 30);
      expect(AiLimits.noteWarnBytes ~/ 1024, 40);
      expect(AiLimits.noteHardBytes ~/ 1024, 50);
    });
  });

  group('分档', () {
    test('空与正常长度是 ok', () {
      expect(noteSizeLevel(''), NoteSizeLevel.ok);
      expect(noteSizeLevel(ascii(1000)), NoteSizeLevel.ok);
    });

    test('刚不到软上限还是 ok', () {
      expect(noteSizeLevel(ascii(AiLimits.noteSoftBytes - 1)),
          NoteSizeLevel.ok);
    });

    test('正好软上限进入 soft（边界是闭区间下界）', () {
      expect(noteSizeLevel(ascii(AiLimits.noteSoftBytes)),
          NoteSizeLevel.soft);
    });

    test('软上限~警告线之间是 soft', () {
      expect(noteSizeLevel(ascii(AiLimits.noteSoftBytes + 1000)),
          NoteSizeLevel.soft);
      expect(noteSizeLevel(ascii(AiLimits.noteWarnBytes - 1)),
          NoteSizeLevel.soft);
    });

    test('正好警告线进入 warn', () {
      expect(noteSizeLevel(ascii(AiLimits.noteWarnBytes)),
          NoteSizeLevel.warn);
    });

    test('40KB~50KB 之间是 warn（仍允许保存）', () {
      expect(noteSizeLevel(ascii(AiLimits.noteWarnBytes + 1000)),
          NoteSizeLevel.warn);
      expect(noteSizeLevel(ascii(AiLimits.noteHardBytes - 1)),
          NoteSizeLevel.warn);
    });

    test('正好 50KB 进入 hard（拒绝保存）', () {
      expect(noteSizeLevel(ascii(AiLimits.noteHardBytes)),
          NoteSizeLevel.hard);
    });

    test('超过 50KB 也是 hard', () {
      expect(noteSizeLevel(ascii(AiLimits.noteHardBytes * 2)),
          NoteSizeLevel.hard);
    });

    test('中文按字节算，不是按字符算', () {
      // 30 万个汉字 = 90 万字节，远超硬上限（50KB）。
      // 如果实现按字符数算（30 万 < 50 K），会误判成 ok。
      expect(noteSizeLevel(cjk(900 * 1024)), NoteSizeLevel.hard);
    });

    test('中文在 80KB 附近的分档也正确', () {
      // 不到 80KB 的中文
      expect(noteSizeLevel(cjk(AiLimits.noteSoftBytes - 3)),
          NoteSizeLevel.ok);
      // 正好 80KB 的中文
      expect(noteSizeLevel(cjk(AiLimits.noteSoftBytes)),
          NoteSizeLevel.soft);
      // 正好 50KB 的中文
      expect(noteSizeLevel(cjk(AiLimits.noteHardBytes)),
          NoteSizeLevel.hard);
    });
  });

  group('裁剪到软上限', () {
    test('超长文本裁到 80KB 以内', () {
      final text = ascii(AiLimits.noteHardBytes * 2);
      final keep = charsForBytes(text, AiLimits.noteSoftBytes);
      final trimmed = text.substring(0, keep);

      expect(utf8ByteLength(trimmed),
          lessThanOrEqualTo(AiLimits.noteSoftBytes));
      // 不该裁得太狠：应当接近上限
      expect(utf8ByteLength(trimmed),
          greaterThan(AiLimits.noteSoftBytes - 4));
    });

    test('中文裁剪按字节算，不切断字符', () {
      final text = cjk(AiLimits.noteHardBytes);
      final keep = charsForBytes(text, AiLimits.noteSoftBytes);
      final trimmed = text.substring(0, keep);

      expect(utf8ByteLength(trimmed),
          lessThanOrEqualTo(AiLimits.noteSoftBytes));
      // 3 字节对齐，没有半个字
      expect(utf8ByteLength(trimmed) % 3, 0);
    });

    test('不超长时一个字都不裁', () {
      final text = ascii(1000);
      final keep = charsForBytes(text, AiLimits.noteSoftBytes);
      expect(keep, text.length);
    });

    test('裁剪后必然落在 ok 或 soft 档（不会再是 hard）', () {
      final text = ascii(AiLimits.noteHardBytes * 3);
      final trimmed =
          text.substring(0, charsForBytes(text, AiLimits.noteSoftBytes));
      expect(noteSizeLevel(trimmed), isNot(NoteSizeLevel.hard));
    });
  });
}
