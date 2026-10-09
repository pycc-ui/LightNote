# 提权把 ATL 载荷解压进 VS 的 MSVC 目录
# 需要管理员：VS 安装目录对普通用户是只读的（BUILTIN\Users:(RX)）。
#
# 【历史脚本】这个脚本只在「VS Build Tools 缺 ATL 头文件（atlstr.h）」时用过一次。
# ATL 已经装进 tools\vsbuildtools 了，正常情况下不会再跑它。
# 留在这里是为了以后换电脑重装 VS 时还有参考。
# 路径从脚本位置推导（tool\legacy\ 往上三层 = 工作区），不写死。
param([switch]$Elevated)

$workspace = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$dl   = Join-Path $workspace 'tools\atl_dl'
$msvc = Join-Path $workspace 'tools\vsbuildtools\VC\Tools\MSVC\14.44.35207'
$log  = Join-Path $workspace 'logs\atl_extract.log'
New-Item -ItemType Directory -Force -Path (Split-Path $log -Parent) | Out-Null

if (-not $Elevated) {
  Write-Output '需要管理员权限，正在请求提权（请在弹出的 UAC 里点「是」）…'
  $psi = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Elevated"
  try {
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $psi -Verb RunAs -PassThru -ErrorAction Stop
    Write-Output "已启动提权进程 PID $($p.Id)，等待完成…"
    $done = $p.WaitForExit(600000)
    if ($done) { Write-Output "提权进程退出码: $($p.ExitCode)" } else { Write-Output '等待超时' }
  } catch {
    Write-Output "提权失败: $($_.Exception.Message)"
    Write-Output '（如果你点了 UAC 的「否」就会出现这个）'
  }
  Write-Output ''
  Write-Output '=== 结果验证（普通权限下检查）==='
  $checks = @(
    'atlmfc\include\atlstr.h',
    'atlmfc\include\atlcom.h',
    'atlmfc\lib\x64\atls.lib',
    'atlmfc\lib\x86\atls.lib',
    'Auxiliary\Microsoft.VC.Paths.x64.ATL.props'
  )
  foreach ($c in $checks) {
    $full = Join-Path $msvc $c
    Write-Output "  $(if (Test-Path $full) {'OK  '} else {'缺失'}) $c"
  }
  return
}

# ---------- 以下在提权进程里执行 ----------
Add-Type -AssemblyName System.IO.Compression.FileSystem
Start-Transcript -Path $log -Force | Out-Null

Write-Output "提权进程 用户: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Output "目标目录: $msvc"
Write-Output ''

$extracted = 0
$failed = 0
foreach ($f in @('ATL.Headers.base.vsix','ATL.X64.base.vsix','ATL.X86.base.vsix')) {
  $zipPath = Join-Path $dl $f
  if (-not (Test-Path $zipPath)) { Write-Output "跳过（不存在）: $f"; continue }
  Write-Output "--- 解压 $f ---"
  $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
  try {
    foreach ($entry in $zip.Entries) {
      if (-not $entry.FullName.StartsWith('Contents/')) { continue }
      if ($entry.FullName.EndsWith('/')) { continue }
      $rel = $entry.FullName.Substring('Contents/'.Length)
      $target = Join-Path $msvc ($rel -replace '/', '\')
      $targetDir = Split-Path $target -Parent
      if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Force -Path $targetDir | Out-Null }
      try {
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        $extracted++
      } catch {
        Write-Output "  失败: $rel -> $($_.Exception.Message)"
        $failed++
      }
    }
  } finally { $zip.Dispose() }
}
Write-Output ''
Write-Output "解压完成：$extracted 个文件，失败 $failed 个"

Write-Output ''
Write-Output '=== 验证 ==='
foreach ($c in @(
  'atlmfc\include\atlstr.h','atlmfc\include\atlcom.h','atlmfc\include\cstringt.h',
  'atlmfc\lib\x64\atls.lib','atlmfc\lib\x86\atls.lib',
  'Auxiliary\Microsoft.VC.Paths.x64.ATL.props','Auxiliary\Microsoft.VC.Paths.x86.ATL.props'
)) {
  $full = Join-Path $msvc $c
  Write-Output "  $(if (Test-Path $full) {'OK  '} else {'缺失'}) $c"
}

Stop-Transcript | Out-Null
