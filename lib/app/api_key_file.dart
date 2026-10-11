import 'dart:io';

import '../core/app_info.dart';

/// 从**程序所在目录**的一个文件读 API Key，仅用于开发与自动化测试。
///
/// ## 为什么需要它
///
/// API Key 正常存在系统钥匙串里（`SecureStore`）。但有些环境钥匙串不可用，
/// 比如受限账户、企业策略拦 AppData、以及本项目的 Windows 沙箱——
/// 那时 `SecureStore` 会降级成"仅本次运行有效"，于是：
///   · 自动化测试没法预置 Key
///   · 手工实跑每次都要重新粘一遍
///
/// 这个入口专门解决那两种情况。
///
/// ## 安全约束（重要）
///
/// 1. **只读程序所在目录**，不是用户目录、不是 AppData。
///    放在 exe 旁边意味着：要读到它必须能往安装目录写文件，
///    这个前提下攻击者本来就能替换 exe 了，多一个 Key 文件不增大攻击面。
/// 2. **只在钥匙串里没有 Key 时才用**。用户自己配过的永远优先——
///    不能出现"用户改了 Key 但被某个文件悄悄覆盖"。
/// 3. 文件名以 `.` 开头，且【**绝不要提交进版本库**】。
///    仓库根目录的 `.gitignore` 里有对应忽略规则。
/// 4. 读到的 Key **不会**被写进钥匙串。它只活在这一个进程里，
///    避免把明文 Key 从"用户临时放置的文件"扩散到持久化存储。
class ApiKeyFile {
  ApiKeyFile._();

  /// 文件名。放在程序所在目录。
  static const fileName = '.lightnote-apikey.txt';

  /// 读一次；没有文件或内容为空都返回 null。
  ///
  /// 失败一律当作"没有"——这个功能只在开发环境用，
  /// 不该因为它让 App 起不来。
  static Future<String?> read() async {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent;
      final f = File('${exeDir.path}${Platform.pathSeparator}$fileName');
      if (!f.existsSync()) return null;

      // 只取第一行非空内容：允许文件里写注释或换行
      final lines = await f.readAsLines();
      for (final line in lines) {
        final t = line.trim();
        if (t.isEmpty) continue;
        if (t.startsWith('#')) continue;
        return t;
      }
      return null;
    } catch (e) {
      // ignore: avoid_print
      print('[$kAppDisplayName] 读取 $fileName 失败（忽略）：$e');
      return null;
    }
  }
}
