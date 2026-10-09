# 把上一版拼错路径的 ATL 文件移到正确位置
# 上一版把内容解到了 <msvc>\VC\Tools\MSVC\14.44.35207\...（多一层），
# 正确位置应该是 <msvc>\atlmfc\... 与 <msvc>\Auxiliary\...
#
# 【历史脚本】同上，ATL 已就位，正常不会再跑。路径从脚本位置推导。
param([switch]$Elevated)

$workspace = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$msvc = Join-Path $workspace 'tools\vsbuildtools\VC\Tools\MSVC\14.44.35207'
$log  = Join-Path $workspace 'logs\atl_move.log'
New-Item -ItemType Directory -Force -Path (Split-Path $log -Parent) | Out-Null

if (-not $Elevated) {
  Write-Output '需要管理员权限移文件，正在请求提权（请点 UAC 的「是」）…'
  $psi = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Elevated"
  try {
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $psi -Verb RunAs -PassThru -ErrorAction Stop
    $p.WaitForExit(600000) | Out-Null
    Write-Output "提权进程退出码: $($p.ExitCode)"
  } catch { Write-Output "提权失败: $($_.Exception.Message)" }

  Write-Output ''
  Write-Output '=== 结果验证 ==='
  foreach ($c in @(
    'atlmfc\include\atlstr.h','atlmfc\include\atlcom.h','atlmfc\include\cstringt.h',
    'atlmfc\lib\x64\atls.lib','atlmfc\lib\x86\atls.lib',
    'Auxiliary\Microsoft.VC.Paths.x64.ATL.props','Auxiliary\Microsoft.VC.Paths.x86.ATL.props'
  )) {
    $full = Join-Path $msvc $c
    Write-Output "  $(if (Test-Path $full) {'OK  '} else {'缺失'}) $c"
  }
  Write-Output ''
  $src = Join-Path $msvc 'VC\Tools\MSVC\14.44.35207'
  Write-Output "残留的多余层级是否已清空: $(-not (Test-Path (Join-Path $src 'atlmfc')))"
  return
}

Start-Transcript -Path $log -Force | Out-Null
Write-Output "提权用户: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"

$srcAtlmfc = Join-Path $msvc 'VC\Tools\MSVC\14.44.35207\atlmfc'
$dstAtlmfc = Join-Path $msvc 'atlmfc'

Write-Output "源: $srcAtlmfc"
Write-Output "目标: $dstAtlmfc"
Write-Output ''

function Move-Tree($from, $to) {
  if (-not (Test-Path $from)) { Write-Output "  源不存在，跳过: $from"; return 0 }
  $n = 0
  Get-ChildItem $from -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($from.Length).TrimStart('\')
    $target = Join-Path $to $rel
    $td = Split-Path $target -Parent
    if (-not (Test-Path $td)) { New-Item -ItemType Directory -Force -Path $td | Out-Null }
    try {
      Move-Item -LiteralPath $_.FullName -Destination $target -Force -EA Stop
      $n++
    } catch {
      # 跨设备或占用时退回复制+删除
      try { Copy-Item -LiteralPath $_.FullName -Destination $target -Force -EA Stop; Remove-Item -LiteralPath $_.FullName -Force -EA SilentlyContinue; $n++ }
      catch { Write-Output "    失败: $rel -> $($_.Exception.Message)" }
    }
  }
  # 清理空目录
  Get-ChildItem $from -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending |
    ForEach-Object { if (-not (Get-ChildItem $_.FullName -Force -EA SilentlyContinue)) { Remove-Item $_.FullName -Force -EA SilentlyContinue } }
  Remove-Item $from -Force -Recurse -EA SilentlyContinue
  return $n
}

$moved = Move-Tree $srcAtlmfc $dstAtlmfc
Write-Output "移动文件数: $moved"

# Auxiliary 里的 ATL props
$srcAux = Join-Path $msvc 'VC\Tools\MSVC\14.44.35207\Auxiliary'
if (Test-Path $srcAux) {
  Get-ChildItem $srcAux -Filter '*ATL*' -File | ForEach-Object {
    $target = Join-Path (Join-Path $msvc 'Auxiliary') $_.Name
    Move-Item -LiteralPath $_.FullName -Destination $target -Force -EA SilentlyContinue
    Write-Output "  移动 props: $($_.Name)"
  }
  Remove-Item $srcAux -Force -Recurse -EA SilentlyContinue
}

# 清掉多余层级
$srcVc = Join-Path $msvc 'VC'
if ((Test-Path $srcVc) -and -not (Get-ChildItem $srcVc -Force -EA SilentlyContinue)) {
  Remove-Item $srcVc -Force -Recurse -EA SilentlyContinue
  Write-Output '已清理多余层级 VC\Tools\MSVC\14.44.35207'
}

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
Write-Output "atlmfc\include 文件数: $((Get-ChildItem (Join-Path $msvc 'atlmfc\include') -File -EA SilentlyContinue).Count)"

Stop-Transcript | Out-Null
