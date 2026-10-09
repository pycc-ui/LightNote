# 完整验证：analyze -> test -> build -> 启动并检查数据库
#
# 临时产物（测试用数据库、运行日志）统一放在 <工作区>\logs\ 下，
# 不再散落在工程目录里。路径从脚本位置推导，不写死。
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'flutter_env.ps1') | Out-Null

$project   = Split-Path -Parent $PSScriptRoot
$workspace = Split-Path -Parent $project
Set-Location $project

$logsRoot = Join-Path $workspace 'logs'
$dbRoot   = Join-Path $logsRoot 'verify_db'
$log      = Join-Path $logsRoot 'verify_app.log'
$errl     = Join-Path $logsRoot 'verify_app.err'
New-Item -ItemType Directory -Force -Path $logsRoot | Out-Null

# 清掉上次 App 建的库，确保是全新启动
Get-Process -Name 'smart_notes' -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep -Seconds 2
if (Test-Path $dbRoot) { Remove-Item $dbRoot -Recurse -Force -EA SilentlyContinue }
New-Item -ItemType Directory -Force -Path $dbRoot | Out-Null

$total = [System.Diagnostics.Stopwatch]::StartNew()

$script:stepCode = 0

# 注意：这里不能用 `return $code`。那样会把返回值混进管道，
# 被外层的 Select-String 之类过滤掉后就变成空字符串，
# 打出来是 "[1/4 flutter analyze] s  exit=0"（秒数没了）。
# 用脚本作用域变量传出，输出保持干净。
function Step($name, [scriptblock]$body) {
  Write-Output ''
  Write-Output ('=' * 62)
  Write-Output "  $name"
  Write-Output ('=' * 62)
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  & $body
  $script:stepCode = $LASTEXITCODE
  $sw.Stop()
  Write-Output ">>> [$name] $([math]::Round($sw.Elapsed.TotalSeconds,1))s  exit=$($script:stepCode)"
}

Step '1/4 flutter analyze' { flutter analyze }
Step '2/4 flutter test'    { flutter test }
Step '3/4 flutter build windows --debug' { flutter build windows --debug }

Write-Output ''
Write-Output ('=' * 62)
Write-Output '  4/4 启动 App 并验证数据库'
Write-Output ('=' * 62)

$exe = Join-Path $project 'build\windows\x64\runner\Debug\smart_notes.exe'
$env:QING_NOTES_DB_DIR = $dbRoot
Remove-Item $log,$errl -Force -EA SilentlyContinue

$p = Start-Process -FilePath $exe -RedirectStandardOutput $log -RedirectStandardError $errl -PassThru
Write-Output "  已启动 PID $($p.Id)"
Start-Sleep -Seconds 22

if ($p.HasExited) {
  Write-Output "  ❌ 已退出，退出码 $($p.ExitCode)"
} else {
  Write-Output "  ✅ 存活  内存 $([math]::Round($p.WorkingSet64/1MB,1)) MB  窗口 '$($p.MainWindowTitle)'"
}

Write-Output ''
Write-Output '  --- 运行时错误（过滤 ERROR/Exception）---'
if (Test-Path $errl) {
  $errs = Get-Content $errl | Where-Object { $_ -match 'ERROR|Exception' }
  if ($errs) { $errs | Select-Object -First 10 | ForEach-Object { Write-Output "    $_" } }
  else { Write-Output '    ✅ 无' }
} else { Write-Output '    (无 stderr)' }

Write-Output ''
Write-Output '  --- 数据库 ---'
$dbs = Get-ChildItem $dbRoot -Recurse -Filter '*.sqlite' -EA SilentlyContinue
if ($dbs) {
  foreach ($d in $dbs) {
    Write-Output "    $($d.FullName.Replace($dbRoot,''))  $($d.Length) 字节"
  }
} else { Write-Output '    ❌ 未创建' }

$total.Stop()
Write-Output ''
Write-Output ('=' * 62)
Write-Output "全部结束  总耗时 $([math]::Round($total.Elapsed.TotalSeconds,1))s"
Write-Output ('=' * 62)
