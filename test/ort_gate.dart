import 'dart:ffi';
import 'dart:io';

/// 嵌入模型（ONNX Runtime 的 FFI 原生库）在这台机器上**能不能加载**。
///
/// ## 为什么需要这么一个开关
///
/// `package:onnxruntime` 是 FFI 的，内部 `DynamicLibrary.open('libonnxruntime.so')`
/// **按名字找**；而 pub 包把 .so 放在
/// `~/.pub-cache/hosted/pub.dev/onnxruntime-<版本>/linux/libonnxruntime.so.1.15.1`
/// —— 既不在默认搜索路径里，名字也差一个 `.1.15.1`。所以本机跑测试必须先设
/// `LD_LIBRARY_PATH`（**进程启动前**，代码里改不了），见 `tool/test.sh`。
///
/// 不处理的话，忘设环境变量会表现为"模型相关的用例全红"，看着像功能坏了 ——
/// 其实是环境没配。所以这里在**注册测试用例之前**同步探一下，探不到就
/// `skip:` 掉，并给出一条能照做的提示。
///
/// ## 判定口径
///
/// · **非 Linux**：直接当"可用"。Android 上库是随 APK 走的（`System.loadLibrary`
///   那套），macOS/Windows 也各有自己的加载方式 —— 这里只管本机 desktop 测试
///   这一个场景，不替真实平台瞎猜。
/// · **Linux**：真的 `DynamicLibrary.open` 一次，成不成看结果。
final bool ortLibraryAvailable = _probe();

/// 探不到时给用例的 `skip:` 值（探到了就是 `false`，表示不跳过）。
///
/// 用法：
/// ```dart
/// test('模型能加载', () async { ... }, skip: ortSkipReason);
/// ```
final Object ortSkipReason = ortLibraryAvailable
    ? false
    : 'ONNX Runtime 原生库加载不到 —— 用 tool/test.sh 跑（它会配好 LD_LIBRARY_PATH）';

bool _probe() {
  if (!Platform.isLinux) return true;
  try {
    DynamicLibrary.open('libonnxruntime.so');
    return true;
  } catch (_) {
    return false;
  }
}
