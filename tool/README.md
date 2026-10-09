# tool/ —— 构建与维护脚本

这个目录放**所有开发期的辅助脚本**。日常你只需要记住一个：

```
双击  ..\rebuild-and-run.cmd        # 编译 + 启动 App
```

其余的都是排查问题或做维护时才用。

## 为什么必须有这些包装脚本

**本机 `dart.exe` 写不了真实的 `AppData`**——它会在遥测初始化时抛
`PathAccessException`（errno 5），**连一行用户代码都跑不到**。实测对照：

| 操作 | 结果 |
|---|---|
| PowerShell 建 `AppData\Roaming\.lightnote` | 成功 |
| 这个 dart 子进程建同一目录 | 拒绝访问 |

所以 `flutter_env.ps1` 把 `APPDATA` / `LOCALAPPDATA` / `TEMP` / `PUB_CACHE`
**重定向到 `<工作区>\tools\appdata` 与 `<工作区>\tools\pub-cache`**，
只在当前进程及其子进程内生效，不写用户级/机器级环境变量。

**因此不要直接敲 `flutter` 命令**——一定失败。用下面的 `.cmd`。

## 为什么用 `.cmd` 而不是 `.ps1`

1. 本机 PowerShell 执行策略会拦截 `.ps1`（`running scripts is disabled`）。
   `.cmd` 内部用 `-ExecutionPolicy Bypass` 调 PowerShell，不需要你改系统设置。
2. `.ps1` 被调用时设的环境变量**在脚本结束后会丢失**；`.cmd` 能保证整条链路
   都在正确环境里。

> `.cmd` 文件**必须保持纯 ASCII**。cmd.exe 用 GBK 码页读它，
> UTF-8 的中文会把解析搞坏（曾经把 `powershell` 这个 token 本身吃掉，
> 报 `'ershell' is not recognized`）。中文输出由 `.ps1` 负责。

## 路径推导（重要）

**所有脚本都从 `$PSScriptRoot` 推导路径，不写死绝对路径。**

这里曾经写死过 `C:\Users\43720\Downloads\py\tools\...`，结果工程
从 `Downloads\py` 搬到 `Downloads\LightNote` 之后，**9 个脚本 24 处路径全部失效**。
现在推导规则是：

```
<工作区>/                      ← 例如 C:\Users\43720\Downloads\LightNote
├── smart_notes/               ← Flutter 工程本体
│   └── tool/                  ← $PSScriptRoot 就在这（或它的子目录）
└── tools/                     ← 工具链：flutter / pub-cache / vsbuildtools / appdata
```

只要保持 **「`smart_notes` 与 `tools` 同级」** 这个相对结构，
整个工作区放在哪个盘、哪一级目录都无所谓。

## 脚本清单

### 日常用

| 脚本 | 作用 |
|---|---|
| `run.cmd <模式>` | **主入口**。模式：`run`（默认，构建+运行）/ `build` / `release` / `test` / `analyze` / `doctor` / `pubget` / `raw <参数>` |
| `run.ps1` | `run.cmd` 调用的实际逻辑，单独调用无效（环境变量会丢） |
| `flutter_env.ps1` | 环境重定向 + PATH。被上面两个点源调用；也可 `. .\tool\flutter_env.ps1` 手动载入当前会话 |

### 排查问题

| 脚本 | 作用 |
|---|---|
| `diag.cmd` | 环境自检：工具链位置 / 符号链接能力 / 平台目录 / Drift 生成代码 / 构建产物 / 执行策略 |
| `doctor.cmd` | `flutter doctor -v` 的包装 |
| `verify_all.cmd` | 一条命令跑完 analyze → test → build → 启动 App 并检查数据库 |
| `inspect_db.cmd [文件]` | 用项目依赖里的 sqlite3 读库：表 / 索引 / 行数 / 内容。不传参数就看默认位置 |

### 构建前置（一般由 `run.ps1` / `flutter_env.ps1` 自动调用）

| 脚本 | 作用 |
|---|---|
| `fix_vs_toolchain.ps1` | 修复「VS 工具链记录位置失效」——用目录联接把老路径接回新位置 |
| `fix_plugin_symlinks.ps1` | 用 `cmd mklink /J` 预先建好 Windows 插件符号链接 |

**`fix_vs_toolchain.ps1` 是干什么的**：Visual Studio 把安装位置记在
`C:\ProgramData\Microsoft\VisualStudio\Packages\_Instances\<id>\state.json` 里，
`vswhere.exe` 读它来回答"VS 装在哪"，`flutter` 又依赖 `vswhere`。
**搬动 `tools` 目录不会同步这个记录**，于是：

- `cl.exe` 明明在新位置能打开
- 但 `vswhere` 报 `isComplete=false`、`state=14`
- `flutter build windows` 报 `Unable to find suitable Visual Studio toolchain`

脚本发现记录位置不存在时，就用 `mklink /J <记录位置> <实际位置>` 接回去，
`vswhere` 一看路径存在立刻恢复 `isComplete=true`。

**代价与根治办法**（完整说明写在该脚本头部注释里）：
VS 的"官方认知"仍然是老路径，**所以那个联接不能删**。
想彻底摆脱它只能：① 用管理员改 `state.json`；② 把 `tools` 搬到固定位置后重装 VS。

**`fix_plugin_symlinks.ps1` 是干什么的**：`flutter build windows` 会为每个插件在
`windows\flutter\ephemeral\.plugin_symlinks\` 下建目录符号链接，
建不出来就直接拒绝构建（`Building with plugins requires symlink support.`）。

本机账户不是管理员，创建符号链接需要 `SeCreateSymbolicLinkPrivilege`。
这个权限在普通登录会话里有（所以 `mklink` 能成功），但在受限令牌下会被剔除，
于是 dart 进程里的 `Link.createSync` 报 `ERROR_PRIVILEGE_NOT_HELD (1314)`。
Flutter 的逻辑是"链接已存在就跳过创建"，所以预先用 `mklink /J` 建好即可绕过。

> 这个脚本还必须能识别**断掉的联接**：junction 里存的是绝对路径，
> 工程一搬家，旧的 junction 就指向不存在的位置，而 `Test-Path` 对断掉的
> junction 返回的是 **true**。早期版本因此误判"已经好了"直接跳过，
> 构建却因为链接无效而失败。现在会解析链接的真实目标再比对，
> 不匹配就删掉重建。

### 辅助检查

| 脚本 | 作用 |
|---|---|
| `check_providers.ps1` | 交叉校验 Provider 注册与实际使用，以及**无类型参数的 `context.read()`** |
| `check_dart_balance.ps1` | 字符级扫描括号与字符串配平 |

这两个是在**还没有 Flutter SDK** 的阶段用来逼近「编译通过」的。
现在 `flutter analyze` 已可用，它们退居辅助——但抓到过 analyze **看不见**的真实缺陷：
`SeedData.ensureSeeded(context.read())` 里裸的 `context.read()` 返回 `BuildContext`，
类型上说得通、静态分析不报，只有真机启动才暴露 `ProviderNotFoundException`。

### 图标

| 文件 | 作用 |
|---|---|
| `icon/make_icon.py` | 生成棕色羽毛笔图标（内置完整 SVG path 解析器） |
| `icon/feather.svg` | 图形来源：Feather Icons v4.29.2（MIT） |
| `icon/out/` | 产物：各尺寸 PNG / `lightnote.ico` / Android mipmap / `preview.png` |

改颜色或粗细：编辑 `make_icon.py` 顶部的 `BROWN`、`STROKE_UNITS`、`CONTENT_RATIO`，
然后 `python tool\icon\make_icon.py`。**注意产物不会自动装进工程**，
还需要手动拷贝到 `windows/runner/resources/` 与 `android/app/src/main/res/mipmap-*/`，
具体命令见 [README](../README.md) 第四节。

### legacy/ —— 历史脚本

| 脚本 | 说明 |
|---|---|
| `legacy/install_atl_elevated.ps1` | 提权把 ATL 载荷解压进 VS Build Tools |
| `legacy/fix_atl_location.ps1` | 修正上一版多解了一层目录的路径 bug |

**正常情况下不会再跑它们。** 保留的原因：它们记录了「VS Build Tools 缺
`atlstr.h` 时怎么把 v143 ATL 装进去」这段过程，以后换电脑重装 VS 时是唯一的参考。
当时踩的坑是用户装了 **v141** ATL 而工程需要 **v143**，
`vs_installer.exe --add` 各种方式都失败（exit 87 / 静默无效），
最后从 `catalog.json` 里取出三个 `.vsix` 的直链，
用 BITS 下载（比 curl 快约 82 倍），再提权解压到 MSVC 目录。

## 脚本改动须知

动这个目录里的脚本时，请守住两条：

1. **不要写死绝对路径。** 从 `$PSScriptRoot` 推导；
   在 `tool/legacy/` 里则往上三层（`tool` → `smart_notes` → 工作区）。
2. **`.cmd` 只能有 ASCII 字符。** 中文写在 `.ps1` 里。
