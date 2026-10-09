# LightNote —— 一键构建/运行脚本
#
# 用法（在 PowerShell 里，当前目录随意）：
#   <工程>\tool\run.cmd              # 构建 debug 并运行
#   <工程>\tool\run.cmd build        # 只构建 debug
#   <工程>\tool\run.cmd release      # 构建 release（可拷走单独用）
#   <工程>\tool\run.cmd test         # 跑测试
#   <工程>\tool\run.cmd analyze      # 静态分析
#   <工程>\tool\run.cmd doctor       # 环境自检
#   <工程>\tool\run.cmd pubget       # flutter pub get
#   <工程>\tool\run.cmd raw <参数>   # 透传任意 flutter 命令
#
# 或者直接双击工程根目录的 rebuild-and-run.cmd。
#
# 一律用 .cmd 而不是 .ps1：本机执行策略会拦截 .ps1，
# 而且 .ps1 的环境变量在脚本结束后会丢失。
#
# 为什么需要包装脚本而不是直接敲 flutter：
#   本机 dart.exe 无法写入真实的 AppData（会抛 PathAccessException，
#   崩在遥测初始化里），所以脚本把 APPDATA / LOCALAPPDATA / TEMP / PUB_CACHE
#   重定向到了工作区目录。详见 tool\flutter_env.ps1 的注释。
#
# 所有路径都从 $PSScriptRoot 推导，不写死绝对路径。

param(
  [ValidateSet('run', 'build', 'release', 'test', 'analyze', 'doctor', 'pubget', 'raw', 'flutterrun')]
  [string]$Mode = 'run',
  [string]$Device = 'windows',
  [string]$Args = ''
)

$ErrorActionPreference = 'Continue'

# 载入环境（重定向 + PATH）
. (Join-Path $PSScriptRoot 'flutter_env.ps1') | Out-Null

$project = Split-Path -Parent $PSScriptRoot
Set-Location $project

Write-Host ''
Write-Host "项目目录: $project" -ForegroundColor Cyan
Write-Host "模式:     $Mode" -ForegroundColor Cyan
Write-Host ''

$sw = [System.Diagnostics.Stopwatch]::StartNew()
# 构建 Windows 之前先补齐插件链接。
# 起因：本机普通用户令牌没有 SeCreateSymbolicLinkPrivilege，
# dart 建符号链接会失败，flutter 直接拒绝构建。详见脚本内注释。
if ($Mode -in @('build', 'release', 'run')) {
  & (Join-Path $PSScriptRoot 'fix_plugin_symlinks.ps1') -ProjectRoot $project
  if ($LASTEXITCODE -ne 0) {
    Write-Host '插件链接修复失败，已中止构建。' -ForegroundColor Red
    exit 1
  }
}

switch ($Mode) {
  'doctor'  { flutter doctor -v }
  'analyze' { flutter analyze }
  'test'    { flutter test }
  'pubget'  { flutter pub get }
  'raw'     { Invoke-Expression "flutter $Args" }
  'build'   { flutter build windows --debug }
  'release' { flutter build windows --release }
  'flutterrun' { flutter run -d $Device }
  'run'     { }   # 构建 + 直接启动 exe，见下面那段
}

# ---------------------------------------------------------------------------
# run 模式：构建完**直接启动 exe**，不用 flutter run
#
# 为什么不用 flutter run（三个都是真实踩到的）：
#
#   1) 它把环境**继承给 App 进程**。而 flutter_env.ps1 为了绕开
#      "dart.exe 写不了真实 AppData" 把 APPDATA 重定向到了 tools\appdata。
#      结果 run.cmd 启动的 App 去假 AppData 里读写数据库，
#      跟双击 exe 得到的**不是同一份笔记**——用户会以为"设置丢了/数据没了"。
#
#   2) 想还原成真实 AppData 也不行：flutter 工具自己要在
#      %APPDATA%\.flutter_tool_state 写状态，还原后它直接崩
#      （实测：Flutter failed to write to a file at "...\.flutter_tool_state"）。
#      父进程和子进程的要求正好相反，同一个环境里没法两全。
#
#   3) 它还占着终端不返回，改一行就得重来一遍。
#
# 直接启动 exe：环境干净（还原成用户真实环境）、立刻返回、与双击完全等效。
# 代价是没有热重载——本项目的迭代节奏用不上。
# 真需要热重载时跑 `.\tool\run.cmd flutterrun`，但要清楚那时的数据库位置
# 在假 AppData 下，跟平时看到的不是同一份。
# ---------------------------------------------------------------------------
if ($Mode -eq 'run') {
  $dbg = Join-Path $project 'build\windows\x64\runner\Debug\smart_notes.exe'

  Write-Host '构建（debug）…' -ForegroundColor Cyan
  flutter build windows --debug
  $code = $LASTEXITCODE

  if ($code -eq 0 -and (Test-Path $dbg)) {
    # 还原成用户真实环境：App 该读写真实 AppData / 文档目录，
    # 而不是构建阶段用的假目录。
    Restore-RuntimeEnv

    # App 会把数据库位置写到它自己的工作目录（= exe 所在目录）。
    # 启动前先清掉上一次的，避免读到过期内容。
    $locFile = Join-Path (Split-Path $dbg -Parent) '.lightnote-storage.txt'
    Remove-Item $locFile -Force -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Host '启动 App…' -ForegroundColor Cyan
    # 工作目录必须是 exe 所在目录：Flutter 桌面端要在那里找 data\ 子目录
    Start-Process -FilePath $dbg -WorkingDirectory (Split-Path $dbg -Parent) | Out-Null

    # 等 App 把数据库位置写出来，然后告诉用户数据在哪。
    # 这一步很重要：用户最常问的就是"我的数据在哪、编译会不会弄丢"，
    # 与其让他去翻设置页或猜 AppData 的目录名，不如每次启动直接打出来。
    $waited = 0
    while (-not (Test-Path $locFile) -and $waited -lt 15) {
      Start-Sleep -Milliseconds 500
      $waited += 0.5
    }

    Write-Host ''
    if (Test-Path $locFile) {
      $info = @{}
      foreach ($line in Get-Content $locFile) {
        $kv = $line -split '=', 2
        if ($kv.Count -eq 2) { $info[$kv[0]] = $kv[1] }
      }
      Write-Host '数据库位置：' -ForegroundColor Cyan
      Write-Host "  $($info['path'])" -ForegroundColor Green

      if ($info['degradedProgramDir'] -eq 'true') {
        Write-Host ''
        Write-Host '  ⚠️  注意：常规位置都不可写，数据临时落在程序目录里。' -ForegroundColor Red
        Write-Host '     这个位置在 build\ 下面，删 build\ 会连数据一起删。' -ForegroundColor Red
        Write-Host '     请到 App 的「设置 → 存储位置」换到安全目录。' -ForegroundColor Red
      } elseif ($info['fallback']) {
        Write-Host '  （发生了降级）' -ForegroundColor Yellow
        Write-Host "  $($info['fallback'])" -ForegroundColor DarkGray
      }
      if ($info['envOverride'] -eq 'true') {
        Write-Host '  （由环境变量 QING_NOTES_DB_DIR 指定）' -ForegroundColor DarkGray
      }
      Write-Host ''
      Write-Host '  重新编译不会影响这个文件。' -ForegroundColor DarkGray
      Remove-Item $locFile -Force -ErrorAction SilentlyContinue
    } else {
      Write-Host '（没能读到数据库位置，可在 App 的「设置 → 存储位置」里查看）' -ForegroundColor DarkGray
    }

    $code = 0
  }
} else {
  # 其它模式已经在上面 switch 里跑完，这里只是取退出码
  $code = $LASTEXITCODE
}

$code = $LASTEXITCODE
$sw.Stop()
$secs = [math]::Round($sw.Elapsed.TotalSeconds, 1)

Write-Host ''
if ($code -eq 0) {
  Write-Host "完成，耗时 ${secs}s" -ForegroundColor Green
} else {
  Write-Host "失败（exit=$code），耗时 ${secs}s" -ForegroundColor Red
}

if ($Mode -in @('build', 'run', 'release')) {
  $sub = if ($Mode -eq 'release') { 'Release' } else { 'Debug' }
  $exe = Join-Path $project "build\windows\x64\runner\$sub\smart_notes.exe"
  if (Test-Path $exe) {
    $size = [math]::Round((Get-Item $exe).Length / 1MB, 2)
    Write-Host ''
    Write-Host "可执行文件: $exe  (${size} MB)" -ForegroundColor Green
    if ($Mode -eq 'release') {
      Write-Host ''
      Write-Host 'Release 版整个目录可以拷到别处或别的电脑单独运行：' -ForegroundColor Cyan
      Write-Host "  $(Split-Path $exe -Parent)"
      Write-Host '（Debug 版不行：依赖工作区里的构建产物）'
    }
  }
}

exit $code
