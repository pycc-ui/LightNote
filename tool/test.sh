#!/usr/bin/env bash
# 跑测试的**唯一入口**。别直接敲 `flutter test` —— 会漏掉下面这件事。
#
# ## 为什么需要这个脚本
#
# 嵌入模型走的是 `package:onnxruntime`（FFI），它内部是
# `DynamicLibrary.open('libonnxruntime.so')` —— **按名字找**，所以进程启动时
# 动态链接器必须能在搜索路径里看到这个 .so。而 pub 包把它放在
# `~/.pub-cache/hosted/pub.dev/onnxruntime-<版本>/linux/libonnxruntime.so.1.15.1`，
# 那个目录不在默认搜索路径里，包名也和 `libonnxruntime.so` 不一致（少了 `.1.15.1`）。
#
# 于是要在临时目录里做两个软链（带 soname 的、和不带的都要），再把目录塞进
# `LD_LIBRARY_PATH`。**环境变量必须在进程启动前设好**，测试代码里改不了 ——
# 这就是它不能写在 Dart 里的原因。
#
# 不做这一步的后果不是"报个错"那么轻：`flutter test` 里凡是碰模型的用例
# 全部失败，看起来像"功能坏了"，其实是环境没配。所以：
#   · 本脚本负责配好它；
#   · 碰模型的测试用例在**没配好时会 skip 而不是 fail**（见 test/ort_gate.dart），
#     免得一个环境问题伪装成一片测试失败。
#
# 用法：
#   tool/test.sh                    # 全量
#   tool/test.sh test/rag_eval_test.dart   # 单个文件
#   tool/test.sh -r expanded        # 参数原样透传给 flutter test
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FLUTTER="${FLUTTER:-flutter}"
if ! command -v "$FLUTTER" >/dev/null 2>&1; then
  for cand in "$HOME/development/flutter/bin/flutter" /opt/flutter/bin/flutter; do
    if [ -x "$cand" ]; then FLUTTER="$cand"; break; fi
  done
fi

# ---- 找到 pub 缓存里的 libonnxruntime.so ----
ORT_SRC="$(ls -1 "$HOME"/.pub-cache/hosted/pub.dev/onnxruntime-*/linux/libonnxruntime.so.* 2>/dev/null | head -1 || true)"

if [ -n "$ORT_SRC" ]; then
  ORT_DIR="${TMPDIR:-/tmp}/lightnote-ort"
  mkdir -p "$ORT_DIR"
  SONAME="$(basename "$ORT_SRC")"                       # libonnxruntime.so.1.15.1
  ln -sf "$ORT_SRC" "$ORT_DIR/$SONAME"
  ln -sf "$ORT_SRC" "$ORT_DIR/libonnxruntime.so"        # 包按这个名字找
  export LD_LIBRARY_PATH="$ORT_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  echo "▸ 原生库：$ORT_SRC"
else
  echo "▸ 没找到 libonnxruntime.so.*：碰模型的用例会被 skip（其余照跑）"
fi

exec "$FLUTTER" test "$@"
