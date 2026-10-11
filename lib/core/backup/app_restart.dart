import 'dart:io';

/// 重启 App。
///
/// 为什么要重启：换数据库文件必须在"数据库尚未打开"的时刻完成。
/// 在运行中换库，Windows 上文件被占用换不掉；就算换掉了，
/// 已打开的连接仍然指向旧文件，之后的读写会落到一个已经被替换掉的文件上。
///
/// 所以导入/切换工作目录统一走「登记意图 + 重启」，这里负责把 App 重新拉起来。
class AppRestart {
  AppRestart._();

  /// 尝试重启，成功返回 true。
  ///
  /// Windows：把当前可执行文件重新拉一个进程，然后退出自己。
  ///   Debug 版的可执行文件在 build\windows\x64\runner\Debug\ 下，
  ///   直接拉那个 exe，工作目录设为 exe 所在目录
  ///   （Flutter 桌面端需要同级的 data/ 子目录才能启动）。
  /// 其它平台：不假装能重启，返回 false，由调用方提示用户手动打开。
  static Future<bool> restart() async {
    if (!Platform.isWindows) return false;

    try {
      final exe = Platform.resolvedExecutable;
      if (!File(exe).existsSync()) return false;

      await Process.start(
        exe,
        const <String>[],
        workingDirectory: File(exe).parent.path,
        mode: ProcessStartMode.detached,
      );
      // 给新进程一点时间把窗口建起来，避免出现"两个都没了"的观感
      await Future<void>.delayed(const Duration(milliseconds: 400));
    } catch (_) {
      return false;
    }

    // exit 是 Never，放在 try 外面，避免 try 块里出现"后面的 return 到不了"
    // 这种既难看又容易被误改的死代码。
    exit(0);
  }

  /// 直接用 `exit(0)` 结束自己（用于平台不支持自重启时的兜底）。
  static Never quitNow() => exit(0);
}
