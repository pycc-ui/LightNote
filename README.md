# LightNote（smart_notes）

Flutter + Dart + SQLite(Drift) + DeepSeek API 的**本地优先**笔记应用。

核心链路：**速记 → 加入笔记库（归目录）→ AI 整理 → 记忆卡片 → 间隔复习 → 沉浸阅读**

> 界面规格见 [docs/界面设计.md](docs/界面设计.md)，
> 实施对照与偏差说明见 [docs/03-界面设计实施说明.md](docs/03-界面设计实施说明.md)，
> 技术选型见 [docs/01-技术选型与架构设计.md](docs/01-技术选型与架构设计.md)，
> 数据模型见 [docs/02-数据模型设计.md](docs/02-数据模型设计.md)。

### 关于命名（唯一的例外）

产品名统一用英文 **LightNote**。除此之外的一切标识**刻意保持不变**：

| 保持不变 | 值 | 原因 |
|---|---|---|
| Dart 包名 | `smart_notes` | 改包名要动全部 `package:` import 和平台工程，风险远大于收益 |
| 数据库文件名 | `qing_notes.sqlite` | **改文件名等于让老用户的数据库凭空消失**（App 会在新路径建一个空库） |
| Windows 可执行文件 | `smart_notes.exe` | 同上，改 BINARY_NAME 会连带影响 CMake 与构建产物路径 |
| 功能名「轻笔记」 | 收件箱 | 这是功能名不是产品名，中文界面里 `LightNote` 反而不自然 |

`lib/core/app_info.dart` 是 Dart 侧身份信息的**唯一来源**（产品名、版本号、包名）。

---

## 〇、目录结构（先看这个）

### 工作区：`C:\Users\43720\Downloads\LightNote\`

```
LightNote/
├── smart_notes/     ← Flutter 工程本体。平时只需要管这一个
└── tools/           ← 工具链（约 9 GB）。不是工程代码，别往里放东西
```

`tools/` 里是装环境时下载的东西，**删掉就得重装**（Flutter SDK 解压约 10 分钟、
VS Build Tools 装了 10.9 分钟、pub 依赖拉取 23.5 分钟）。里面：

| 子目录 | 是什么 |
|---|---|
| `flutter/` | Flutter SDK 3.47.6 |
| `pub-cache/` | pub 依赖缓存（120 个项目依赖 + flutter_tools 依赖） |
| `vsbuildtools/` | Visual Studio Build Tools 2022（MSVC + Windows SDK + ATL） |
| `appdata/` `temp/` | `flutter_env.ps1` 重定向用的假 AppData 与临时目录 |
| `atl_dl/` | 当年手工装 v143 ATL 时下载的三个 `.vsix`（可删） |
| `flutter_windows_3.47.6-stable.zip` | SDK 原始压缩包，**1.9 GB，装完就可以删** |
| `_speed.bin` `*.log` | 测速与安装日志，可删 |

> `smart_notes` 与 `tools` **必须保持同级**：所有脚本都按这个相对结构推导路径
> （见 [tool/README.md](tool/README.md)）。整个 `LightNote` 目录可以整体搬到
> 任意位置，脚本不用改。但**不要只搬 `smart_notes`**——那就找不到工具链了。

### ⚠️ `Downloads\py\tools\vsbuildtools` 是个目录联接，**不能删**

你会看到 `C:\Users\43720\Downloads\py\tools\vsbuildtools`，它**不是真的目录**，
而是一个指向 `Downloads\LightNote\tools\vsbuildtools` 的联接（junction）。

**为什么需要它**：Visual Studio 把安装位置记在
`C:\ProgramData\Microsoft\VisualStudio\Packages\_Instances\84d3e4f9\state.json` 里，
`vswhere.exe` 读它来回答"VS 装在哪"，`flutter` 又依赖 `vswhere`。
**搬动 `tools` 目录不会同步这个记录**，于是出现很坑的现象：

- `cl.exe` 明明在新位置能打开
- 但 `vswhere` 报 `isComplete=false`、`state=14`
- `flutter build windows` 报 `Unable to find suitable Visual Studio toolchain`

`tool\fix_vs_toolchain.ps1` 会在每次构建前检查，发现记录位置失效就**自动重建联接**。
实测：删掉联接后跑 `rebuild-and-run.cmd`，脚本自动接回并构建成功（12.3 秒）。

**如果哪天它彻底接不回来了**，两个根治办法：

1. 用管理员权限改 `state.json` 里的 `installationPath` 指向新位置；
2. 把 `tools` 搬到一个你打算长期不动的位置，重装 VS Build Tools。

（第三条路：把 `tools` 搬回原位置 `Downloads\py\tools`，那就什么都不用改。
这也是为什么当初把工具链放在工作区里——整个目录可以一起搬。）

### 工程：`smart_notes/`

```
smart_notes/
├── README.md               ← 你正在看的
├── rebuild-and-run.cmd     ← 日常唯一入口：编译 + 启动
├── pubspec.yaml            ← 依赖与版本
├── analysis_options.yaml   ← lint 规则
│
├── lib/                    ← 全部 Dart 源码（见下）
├── test/                   ← 测试（3 个文件，75 个用例）
├── docs/                   ← 设计与实施文档
├── tool/                   ← 构建与维护脚本（见 tool/README.md）
│   └── legacy/             ← 历史安装脚本，正常不会再跑
│
├── android/                ← Flutter 生成的 Android 工程
├── windows/                ← Flutter 生成的 Windows 工程
├── build/                  ← 构建产物。可随时删，删了重新编译
├── .dart_tool/             ← Dart 的中间状态。可删，删了要重新 pub get
└── .idea/  *.iml           ← IDE 配置
```

**`android/` `windows/` `build/` `.dart_tool/` `.idea/` 都是生成物，不要手工维护**，
只有 `windows/runner/Runner.rc`（版本信息）、`windows/runner/main.cpp`（窗口标题）、
`android/app/src/main/AndroidManifest.xml`（应用名与图标）这三处需要改，而且
改它们属于「改产品外观」，不是日常开发。

### `lib/` 的内部结构（feature-first）

```
lib/
├── main.dart                 ← 入口：依赖装配 + 启动前换库/自检
├── core/                     ← 与具体功能无关的基础设施
│   ├── app_info.dart         ← 产品名 / 版本 / 包名（唯一来源）
│   ├── db/                   ← 数据库：表定义、连接、位置解析
│   ├── secure/               ← 系统钥匙串（API Key）
│   ├── theme/                ← 主题与尺寸常量
│   ├── seed/                 ← 首次启动的示例数据
│   └── util/
├── features/                 ← 按功能分，每个功能自带 data/domain/ui
│   ├── notes/                ← 轻笔记、笔记库、编辑、搜索
│   ├── folders/              ← 目录
│   ├── ai/                   ← DeepSeek 客户端、提示词、AI 页
│   ├── cards/                ← 记忆卡片与 SM-2 调度
│   ├── reader/               ← 沉浸阅读
│   └── settings/             ← 设置页
└── services/                 ← 跨功能的服务
    ├── backup/               ← 备份包导出 / 导入 / 工作目录
    ├── markdown_export_service.dart
    └── preferences_service.dart
```

判断一个新文件该放哪，问一句：**「它只服务于某一个功能吗？」**
是 → `features/<那个功能>/`；否 → `core/`（基础设施）或 `services/`（跨功能服务）。

### 已经清掉的噪音

| 曾经存在 | 处理 |
|---|---|
| `Downloads\py\` 下的旧工程副本 | 已删。**但 `Downloads\py\tools\vsbuildtools` 这个联接必须留着**，见上面 |
| `Downloads\py\logs\` `appdata_test\`（早期调试残留） | 已删。临时产物现在统一进 `<工作区>\logs\` |
| `tool\verify_app.ps1` | 已删。功能被 `rebuild-and-run.cmd` 与 `verify_all.cmd` 覆盖 |
| `tool\install_atl_elevated.ps1` / `fix_atl_location.ps1` | 移入 `tool\legacy\`（ATL 早已装好，留着当参考资料） |
| `tool\icon\out\` 里的 16 个生成图 | 加进 `.gitignore`，只保留 `preview.png` 供文档引用 |

### ⚠️ 第二个已修的坑：VS 工具链的记录位置

搬工程之后 `flutter build windows` 报 `Unable to find suitable Visual Studio toolchain`。
原因和修法见上面「目录联接」那一节。新增了 `tool\fix_vs_toolchain.ps1`，由
`flutter_env.ps1` 在每次构建前自动调用。

另外 **`build\windows\` 里的 CMake 缓存写死了绝对源码路径**，
搬工程后即使工具链修好了也会报：

```
CMake Error: The current CMakeCache.txt directory ... is different than the directory
c:/Users/43720/Downloads/py/smart_notes/build/windows/x64 where CMakeCache.txt was created.
```

处理：删掉 `build\windows\` 重编即可（本次实测重建耗时 48.5 秒：
清缓存后首次完整编译；之后的增量编译回到 12–20 秒）。

### ⚠️ 一个已修的坑：脚本里写死了绝对路径

搬到 `Downloads\LightNote` 之后，**9 个脚本里的 24 处
`C:\Users\43720\Downloads\py\...` 全部失效**，`rebuild-and-run.cmd` 直接不能用了。

现在所有脚本都改成从 `$PSScriptRoot` 推导：

```
$toolDir   = $PSScriptRoot        # 本脚本所在目录
$project   = 上一级                # smart_notes
$workspace = 再上一级              # LightNote
$toolsRoot = <工作区>\tools
```

**以后改脚本请守住这条**：不要写死绝对路径，从 `$PSScriptRoot` 推。
（`tool\legacy\` 里的两个往上三层。）

---

## 一、环境状态（已装好并验证）

本机原本没有任何 Flutter 工具链，现已装好：

| 组件 | 版本 | 位置 |
|---|---|---|
| Flutter SDK | **3.47.6**（stable，SHA256 与官方一致） | `..\tools\flutter` |
| Dart SDK | **3.13.5** | 随 Flutter 附带 |
| Git | 2.55.0 | `C:\Program Files\Git` |
| **Visual Studio Build Tools 2022** | 17.14.41（含 MSVC 14.44 + Windows SDK 10.0.26100 + ATL） | `..\tools\vsbuildtools` |
| pub 缓存 | 120 个项目依赖 + flutter_tools 依赖 | `..\tools\pub-cache` |

**实测结果（完整跑通）：**

```
flutter analyze              →  No issues found!              (4.8s)
flutter test                 →  All tests passed!  75/75      (5.2s)
flutter build windows --debug   →  √ Built smart_notes.exe    (15.1s)
flutter build windows --release →  √ Built smart_notes.exe    (76.8s)
启动 App（Debug / Release）  →  窗口标题 LightNote，无未捕获异常
数据库                       →  12 张表 + 10 个索引 + 种子数据（2 笔记 + 1 目录）
```

### ⚠️ 本机有一个必须绕过的环境问题

**本机 `dart.exe` 无法写入真实的 `AppData`**，会在遥测初始化时抛
`PathAccessException`（errno 5）直接崩掉，连一行用户代码都跑不到。实测对照：

| 操作 | 结果 |
|---|---|
| PowerShell 建 `AppData\Roaming\LightNote` | 成功 |
| 这个 `dart run` 子进程建同一目录 | 拒绝访问 |
| 重定向 `APPDATA`/`LOCALAPPDATA`/`TEMP`/`PUB_CACHE` 到工作区 | **成功** |

所以**不要直接敲 `flutter` 命令**，用包装脚本。**用 `.cmd` 版本，不要用 `.ps1`**：

```powershell
cd C:\Users\43720\Downloads\LightNote\smart_notes
.\rebuild-and-run.cmd       # ← 日常就用这个：编译 + 启动，失败会停住显示错误
.\tool\run.cmd              # 等价（不 pause）
.\tool\run.cmd build        # 只构建 debug
.\tool\run.cmd release      # 构建 release（整个目录可拷走单独运行）
.\tool\run.cmd test         # 只跑测试（75/75，约 5s）
.\tool\run.cmd analyze      # 静态分析
.\tool\run.cmd pubget       # flutter pub get
.\tool\run.cmd doctor       # 环境自检
.\tool\run.cmd raw <参数>   # 透传任意 flutter 命令（排查问题时用）
.\tool\diag.cmd             # 诊断：符号链接 / 平台目录 / 生成代码 / 产物
.\tool\verify_all.cmd       # 一条命令跑完 analyze+test+build+启动验证
.\tool\inspect_db.cmd       # 用 sqlite3 查看 App 建的库（表/索引/数据）
```

**为什么不直接用 `run.ps1`**：两个原因。

1. 本机 PowerShell 执行策略会拦截 `.ps1`（`running scripts is disabled`）。
   `.cmd` 不受该策略限制，它内部用 `-ExecutionPolicy Bypass` 调 PowerShell，
   不需要你改任何系统设置。
2. 即使绕过策略，`.\tool\run.ps1` 这种调用方式下脚本设的环境变量
   **会在脚本结束后丢失**；而 `.cmd` 能保证整条构建链路都在正确环境里。

> 注意：`.cmd` 文件**必须保持纯 ASCII**。cmd.exe 用 GBK 码页读它，UTF-8 的中文
> 会把解析搞坏（曾经把 `powershell` 这个 token 本身吃掉，报
> `'ershell' is not recognized`）。中文输出由 `.ps1` 负责。

### ⚠️ 符号链接问题（已自动化，不用你操心）

`flutter build windows` 在含插件时会为每个插件建目录符号链接，建不出来就拒绝构建：

```
Building with plugins requires symlink support.
```

原因：本机 `RUTOLAPTOP\43720` 不是管理员，创建符号链接需要
`SeCreateSymbolicLinkPrivilege`。这个权限在普通登录会话里有（所以 cmd 的 `mklink`
能成功），但在受限令牌里会被剔除，于是 dart 进程里的 `Link.createSync` 报
`ERROR_PRIVILEGE_NOT_HELD (1314)`。

**处理办法**：`tool\run.ps1` 在 `build` / `release` / `run` 之前会自动调用
`tool\fix_plugin_symlinks.ps1`，用 `cmd mklink /J` 预先建好这些链接。
Flutter 的逻辑是"链接已存在就跳过创建"，所以报错不再发生。
这个脚本会把补齐的链接数打出来；真有建不出来的会明确列出插件名与两种修法。

### 构建时的环境重定向不能带到运行期

构建时必须重定向 `APPDATA`/`TEMP`（否则 dart 写不了 AppData），
但**运行时重定向会害了 App**：`flutter_secure_storage_windows` 与 `path_provider`
拿到的真实用户路径在重定向后的环境里不存在。
所以 `run.ps1` 只在构建阶段重定向，启动 App 时用干净环境。

---

## 二、数据存在哪（默认私有 + 可换工作目录）

### 默认：App 私有目录

```
Windows :  %APPDATA%\<公司名>\<产品名>\LightNote\qing_notes.sqlite
Android :  /data/data/<包名>/files/LightNote/qing_notes.sqlite
```

用户不需要知道、也不应该去翻这个目录——设置页会把真实路径显示出来，
并提供「导出备份包」作为拿数据的正规出口。

> 老版本（v1.0）曾把数据库放在 `文档\轻笔记\`。改成私有目录后，
> **老库不会自动迁移**，App 会在新位置建一个空库。开发阶段直接删掉旧文件即可；
> 正式发布前必须补一段"首次启动时探测老路径并迁移"的逻辑。

### 目录解析顺序

`lib/core/db/database_location.dart` 逐个**真实试写**（目录存在 != 可写）：

| 顺序 | 位置 | 说明 |
|---|---|---|
| 1 | 环境变量 `QING_NOTES_DB_DIR` | 调试 / CI / 自动化用，优先级最高 |
| 2 | 用户在设置里指定的工作目录 | 存在 `storage.json`（不在数据库里，否则先有鸡还是先有蛋） |
| 3 | `getApplicationSupportDirectory()/LightNote` | **默认** |
| 4 | `getApplicationDocumentsDirectory()/LightNote` | 第 3 步目录建不出来时的备选 |
| 5 | `%USERPROFILE%\LightNote` | 最后备选 |

- **刻意不把「系统临时目录」列为候选**：临时目录会被系统清理，
  把笔记库放进去等于埋一个"过几天数据没了"的定时炸弹。宁可报错也不要静默丢数据。
- 任何降级都会：① 控制台打印原因；② 在设置页「存储位置」卡片上如实展示，
  带一个红色提示条说明"你指定的目录这次没用上"。
- 全部候选都失败时，启动页会显示诊断页（列出每个候选各自的错误），
  而不是留一个转圈的空白壳。

### 更换工作目录（设置 → 存储位置 → 更换工作目录）

1. 系统目录选择器选一个目录（Windows 走 `IFileDialog`，Android 走 SAF，**不需要存储权限**）；
2. App 用 `VACUUM INTO` 生成**一致性快照**复制过去（不是文件拷贝，见下）；
3. 写入配置，提示重启；重启后在启动瞬间生效。

目标目录里已经存在 `qing_notes.sqlite` 时**绝不覆盖**，会问你是「使用它」还是「换个目录」。

> 为什么用 `VACUUM INTO` 而不是 `File.copy`：数据库正在被写，
> 默认 journal 模式下最近一次事务可能还在 `-journal` 文件里，
> 直接拷主文件可能得到一个**少了最后一次提交**的库，拷到一半还可能撕裂。
> `VACUUM INTO` 由 SQLite 自己保证一致性，输出也是整理过的完整库。

---

## 三、备份与恢复

设置页「备份与恢复」两个入口。备份包就是**普通 zip**，用任何解压软件都能打开检查：

```
LightNote-20260213-1045.zip
├── backup.json                   清单：格式版本、App 版本、库版本、统计、SHA-256
└── data/
    └── qing_notes.sqlite         标准 SQLite 文件
```

**刻意不包含 API Key**：它在系统钥匙串里，不属于笔记数据，
而备份包通常会被丢进网盘或聊天记录，不能顺手把密钥也带出去。

### 导出

`导出备份包（.zip）` → 系统保存对话框选位置（含文件名）。
不选位置就直接落到私有目录的 `backups/`；选了外部位置时**额外**在私有目录留一份
（U 盘丢了、或者导进了某个 App 私有沙盒再也找不到时，还有的救）。

### 导入（换库发生在下次启动）

`从备份包导入` → 选 zip → **三层校验** → 确认策略 → 重启换库。

校验顺序（任一步失败都给出可读原因，不写任何数据）：

1. 是不是合法 zip、有没有 `backup.json`、清单能否解析、格式/库版本是否兼容；
2. 数据库条目在不在、大小与 **SHA-256** 是否与清单一致（发现传输损坏）；
3. 文件头是不是 `SQLite format 3`、能否真的打开、
   `PRAGMA integrity_check` 是否为 `ok`、必需表（notes/folders/cards/settings）是否齐全。

**为什么换库要等重启**：导入时数据库已经打开着。Windows 上打开中的 sqlite 文件
既不能改名也不能覆盖；就算强行换掉，已建立的 drift 连接指向的还是旧文件，
之后所有读写都会落到一个"已经不属于 App"的文件上——这类不一致比导入失败严重得多。
所以导入只登记意图（`pending_import.json`），换库在 `main()` 里、
**任何数据库连接建立之前**完成，那段代码是纯文件操作。

导入策略：

| 策略 | 旧库去哪 |
|---|---|
| 覆盖当前数据（默认） | 先拷进私有目录 `backups/before-import-<时间>.sqlite` |
| 保留为另一个文件 | 改名成 `before-import-<时间>.sqlite` 留在原工作目录 |

重启后会有一个 SnackBar 明确告诉你导入了几条数据、旧库留档在哪。

---

## 四、图标

棕色羽毛笔，由脚本生成，**没有引用任何二进制素材**：

```powershell
python tool\icon\make_icon.py
```

- 图形来源：Feather Icons v4.29.2 的 `feather` 图标（MIT），
  路径数据在 `tool/icon/feather.svg`。
- `tool/icon/make_icon.py` 里内置了一个完整的 SVG path 解析器
  （M/L/H/V/C/S/Q/T/A/Z），因为本机没有 cairosvg 而 Pillow 不能直接画 SVG。
  改颜色/粗细只要改文件顶部的 `BROWN`、`STROKE_UNITS`、`CONTENT_RATIO` 再重跑。
- 输出到 `tool/icon/out/`：各尺寸 PNG、`lightnote.ico`、Android 各密度 mipmap、
  透明背景 `lightnote_logo.png`、以及深浅底对照的 `preview.png`。
- 安装到工程里（这也是 `make_icon.py` 之后要手动做的一步）：

```powershell
copy tool\icon\out\lightnote.ico windows\runner\resources\app_icon.ico
foreach ($d in 'mdpi','hdpi','xhdpi','xxhdpi','xxxhdpi') {
  copy tool\icon\out\android\mipmap-$d\ic_launcher.png android\app\src\main\res\mipmap-$d\ic_launcher.png
}
```

界面主色也随之从设计稿的蓝灰 `#4A6FA5` 改成棕色 `#7C522C`
（`lib/core/theme/app_theme.dart`），否则图标是棕色、界面是蓝色会很割裂。

---

## 五、命令速查

```powershell
cd C:\Users\43720\Downloads\LightNote\smart_notes
. .\tool\flutter_env.ps1          # 载入环境（点源，当前会话生效）
                                  # 注意：执行策略会拦 .ps1，用 run.cmd 更省事

flutter analyze                   # 静态分析，当前零问题
flutter test                      # 75 个测试
flutter run -d windows            # 桌面调试
flutter devices                   # 查看真机
flutter run -d <device-id>        # 真机运行
dart run build_runner build       # 改过表结构（tables.dart）后重新生成 Drift 代码
```

平台目录（`android/`、`windows/`）已由 `flutter create` 生成完毕，无需再跑。

**改了数据库表结构之后**：

```powershell
dart run build_runner build       # 重新生成 app_database.g.dart
.\tool\run.cmd build
```

开发阶段最简单是直接删库让它重建（`%APPDATA%\<公司>\<产品>\LightNote\qing_notes.sqlite`）。
一旦对外发布，改表必须新增 `schemaVersion` 并写迁移，见 `app_database.dart` 的注释。

---

## 六、第一次上手

1. 启动 App。首次会写入两条示例笔记与一个「工作笔记」目录，方便看懂流程。
   底部四个标签：**轻笔记 / 笔记库 / AI / 设置**。
2. 「轻笔记」页点**记一笔**写点东西 —— 这是速记，不需要先想标题和分类。
3. 想清楚归属后，点卡片上的**加入笔记库**，选一个目录。
4. 「笔记库」页按目录管理；`+` 能新建笔记或新建目录；长按有移动/删除菜单。
5. 「笔记库 → 右上角更多」里有**记忆卡片复习**入口（显示今天待复习数量）。
6. 「AI」页：先在「设置」填 DeepSeek API Key，再回来用。
   首次会弹一次数据说明，确认后才能发送。
7. 打开任意笔记，右上角 ✨ 可「AI 整理要点」或「生成记忆卡片」。
8. 想换存储位置或做备份：**设置 → 存储位置 / 备份与恢复**。

---

## 七、已实现能力

| 能力 | 位置 |
|---|---|
| 轻笔记（收件箱）卡片流 | `features/notes/ui/inbox_page.dart` |
| 笔记库：目录树 + 最近笔记 + 长按菜单 | `features/notes/ui/library_page.dart` |
| 目录详情：目录内笔记、新建子目录 | `features/notes/ui/folder_detail_page.dart` |
| 编辑页：保存状态、格式工具栏、自动保存 500ms | `features/notes/ui/note_editor_page.dart` |
| 搜索：实时搜索、关键词高亮、搜索历史 | `features/notes/ui/search_page.dart` |
| AI 页：工作区 / 思考强度 / 选文件 / 指令 / 会话历史 | `features/ai/ui/ai_page.dart` |
| 设置：外观 / 编辑器 / 存储位置 / 备份恢复 / AI / 卡片 / 用量 / 关于 | `features/settings/ui/settings_page.dart` |
| **整库备份包导出（zip + 清单 + SHA-256）** | `services/backup/backup_service.dart` |
| **备份包导入（三层校验 + 重启换库）** | `services/backup/pending_import.dart` |
| **工作目录可配置（默认 App 私有）** | `core/db/database_location.dart` |
| Markdown 导出（按目录整理成单个 .md） | `services/markdown_export_service.dart` |
| DeepSeek 流式客户端（SSE、思考模式、错误映射） | `features/ai/data/deepseek_client.dart` |
| JSON Output 三级解析降级 + 3 次重试 | `features/ai/domain/prompts.dart` |
| 摘要 / 要点 / 标签 / 待办 + 自动打标签 | `features/ai/domain/ai_repository.dart` |
| 记忆卡片生成 + 人工确认后入库 | `features/cards/ui/card_review_sheet.dart` |
| SM-2 调度器（4 档评分、EF 钳制） | `features/cards/domain/review_scheduler.dart` |
| 沉浸阅读 + AI 摘要速读 + 进度记忆 | `features/reader/ui/reader_page.dart` |
| 删除目录不删笔记（笔记回到轻笔记） | `app_database.dart` → `softDeleteFolder` |
| API Key 存系统钥匙串 + 不可用时降级为会话内存储 | `core/secure/secure_store.dart` |
| 成本估算与累计统计 | `deepseek_config.dart` + 设置页 |

### 刻意留到后续版本

- **Android 打包**：JDK 与 Android SDK 尚未安装（`android/` 工程与图标已就绪）
- **TTS 朗读**（阅读三层设计的 L3）
- **FTS5 中文全文检索**：当前是 `LIKE`，中文没分词，长文会漏。
  drift 打包的 SQLite 已启用 FTS5，不用换库，只需加虚拟表。
- **数据库加密**
- **老版本数据库自动迁移**（v1.0 的 `文档\轻笔记\` → 私有目录）
- **回收站 UI**：数据层已支持逻辑删除，缺恢复界面
- **多设备同步**：表结构已预留（UUID 主键、`updatedAt`、`deletedAt`）

---

## 八、编译期修掉的那些问题（备查）

`flutter analyze` 第一次跑出 **58 个问题**，全部已修。记录在此，避免重复踩：

| 问题 | 原因与修法 |
|---|---|
| `Card` 名字冲突 | Drift 从 `cards` 表生成了 `Card` 类，撞上 Flutter 的 `Card` 组件。纯 UI 文件用 `hide Card`；`review_page.dart` 两者都要用，改用导入别名 `as db` + `db.Card` |
| 测试里 `isNull`/`isNotNull` 冲突 | drift 与 `flutter_test` 的 matcher 同名，drift 侧 `hide isNull, isNotNull` |
| `replaceAll` 传回调 | 该 API 只接受字符串替换值，改用 `replaceAllMapped` |
| `Utf8Decoder(...).decoder` | 该 getter 不存在，改用 `utf8.decoder` |
| `switch (DioExceptionType)` 不穷尽 | Dio 5.x 新增 `transformTimeout`，补上 case |
| `Companion` 缺 `createdAt` | upsert 内部是 INSERT ... ON CONFLICT，必须带齐「非空且无默认值」的列。`saveContent` 从已读出的行带回该值 |
| `AiMessagesCompanion` 的字段类型 | `content` 需包 `Value(...)`，`createdAt` 必填 |
| `usageCount` 被重复累加 | **真实逻辑 bug**：`InsertMode.insertOrIgnore` 冲突时仍返回 1（尝试写入行数，非实际插入数），不能用它判断是否插入。改为先查存在性 |
| JSON 降级解析残留引号 | 降级路径要顺手剥掉 `[]"`，否则得到 `'["正常项"'` |
| `_2` 命名不规范 | 改名 `_pad2` |
| 默认 `widget_test.dart` | `flutter create` 生成的，引用不存在的 `MyApp`，已删 |

`analysis_options.yaml` 把 `use_build_context_synchronously` 降为 `ignore`：
5 处都是确认过的误报（每处都有 `mounted` 守卫，只是 analyzer 在 `switch`
分支里跟踪不到），文件内有详细说明。

### 加备份功能时又踩到的（第二批）

| 问题 | 原因与修法 |
|---|---|
| `RadioListTile` 的 `groupValue`/`onChanged` 废弃 | Flutter 3.32 起改用 `RadioGroup` 包裹；旧写法在 analyze 里刷四条 deprecation |
| 私有目录解析抛异常打崩设置页 | `DatabaseLocation.describe()` 里不能假设 `privateRoot()` 成功：数据库可能是靠环境变量跑起来的。每一段单独容错 |
| 安全存储异常冒到 UI | `flutter_secure_storage_windows` 把数据存在 `%APPDATA%\<公司>\<产品>\`，目录建不出来时抛 `PathAccessException`，会从 `AiRepository.init()` 冒出来打红屏。`SecureStore` 现在每个方法都降级为"没有配置"，并退到会话内存储 |
| 数据库打不开时只留转圈空白壳 | 加了启动前的 `_StartupGate`：真跑一次 `SELECT 1`，失败就显示诊断页（列出每个候选目录各自的错误） |

---

## 九、成本控制要点（容易忽略）

1. **思考模式默认是开的**。DeepSeek 官方文档写明「思考模式默认打开，且 effort 默认为 high」。
   本 App 在摘要、问答、连通性测试上都显式传 `thinking: {"type": "disabled"}`，
   AI 页只有思考强度选「中」或「高」时才开启。**这是省钱的关键点。**

2. **空闲时段价格是高峰的一半**。高峰 = 北京时间周一至周五（非法定节假日）
   9:00–12:00、14:00–18:00。批量任务建议放到周末或晚上。

3. **缓存命中后输入成本约降到 1/50**。所以 `prompts.dart` 的 system prompt 保持稳定，
   且**绝不把时间戳、随机 ID 放进 prompt 开头**。

4. **思考模式下 `temperature` 无效**（官方：设置了不报错也不生效）。
   提升稳定性要靠 prompt 约束 + JSON Output，不是靠调温度。

---

## 十、常见问题

**Q：直接敲 `flutter` 报 `PathAccessException`，或卡在 `Running pub upgrade...` 反复重试？**
没载入环境包装。用 `.\tool\run.cmd`，或先 `. .\tool\flutter_env.ps1`。详见第一节。

**Q：`flutter build windows` 报需要符号链接？**
已在 `run.ps1` 里自动修复（`tool\fix_plugin_symlinks.ps1`）。
如果你绕过 `run.cmd` 直接敲 `flutter build`，就会再遇到；那就用回 `run.cmd`。

**Q：`build_runner` 报 `app_database.g.dart` 相关错误？**
`flutter clean` 后重试；仍失败就 `dart run build_runner clean` 再 build。

**Q：AI 一直报 401？**
Key 复制时带了空格或换行（本 App 会自动 trim）。若 Key 本身过期需重新生成。

**Q：生成卡片返回空？**
官方承认 JSON Output 有概率返回空 content。代码已内置 3 次重试 + 三级解析降级。
若仍为空，通常是笔记太短或过于零散。

**Q：数据库文件在哪？**
默认在 App 私有目录，**设置 → 存储位置**里能看到完整路径。
Windows 上通常是 `%APPDATA%\<公司名>\<产品名>\LightNote\qing_notes.sqlite`。
想自己用 DB Browser 打开，先「导出备份包」，解压出来的 `data\qing_notes.sqlite`
就是标准库文件。

**Q：换电脑 / 换手机怎么搬数据？**
「设置 → 导出备份包」，把 zip 拿过去，在新设备上「从备份包导入」。
**不包括 API Key**，需要在新设备上重新填一次。

**Q：导出的 Markdown 在哪？**
App 内部目录，文件名形如 `轻笔记导出_2026-10-08T21-30-00.md`。
只适合临时取用；要长期保存请用 zip 备份包。

**Q：Android 上「更换工作目录」点了没反应？**
Android 的 SAF 目录可能只返回 `content://` URI，Dart 的 `dart:io` 写不了这种路径。
这种情况下界面会提示改用导出/导入备份包（Android 上的正解）。

---

## 十一、附带的校验脚本

| 脚本 | 作用 |
|---|---|
| `rebuild-and-run.cmd` | **日常入口**：编译 + 启动，失败会 pause 让你看错误 |
| `tool/run.cmd` | **主入口**：构建 / 运行 / 测试 / 分析 / pubget / 透传 |
| `tool/run.ps1` | `run.cmd` 调用的实际逻辑 |
| `tool/fix_plugin_symlinks.ps1` | 用 `mklink /J` 补齐插件符号链接（构建前置步骤） |
| `tool/verify_all.cmd` | 一条命令跑完 analyze + test + build + 启动验证 |
| `tool/inspect_db.cmd` | 用 sqlite3 检查 App 建的库（表 / 索引 / 行数 / 内容） |
| `tool/icon/make_icon.py` | 生成棕色羽毛笔图标（含完整 SVG path 解析器） |
| `tool/diag.cmd` / `diag.ps1` | 环境自检：工具链 / 符号链接 / 平台目录 / 生成代码 / 产物 |
| `tool/doctor.cmd` | `flutter doctor -v` 的包装 |
| `tool/flutter_env.ps1` | 环境重定向包装（一切命令的基础） |
| `tool/check_dart_balance.ps1` | 字符级扫描括号与字符串配平 |
| `tool/check_providers.ps1` | 校验 Provider 注册/使用，以及**无类型参数的 `context.read()`** |

后两个是在没有编译器的阶段用来逼近「编译通过」的，现在 `flutter analyze`
已可用，它们退居辅助。但它们抓到过 `flutter analyze` **看不见**的真实缺陷：

- 非法的 raw 字符串字面量、5 处缺一层的相对 import
- **`context.read()` 不带类型参数**导致运行时 `ProviderNotFoundException`
  （`SeedData.ensureSeeded(context.read())` 让 AI 页每次打开就抛异常；
  类型上说得通，静态分析不报，只有真机启动才暴露）
