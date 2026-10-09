# Dart 括号平衡检查器（字符级扫描）
# 注意：PowerShell 中 [char] 与单字符字符串做 -eq 恒为 false，
# 因此这里统一用 [int] 码点比较，避免重蹈覆辙。
param(
  # 默认扫描本脚本所在工程。原来写死了绝对路径，工程一搬家就失效。
  [string]$Root = (Split-Path -Parent $PSScriptRoot)
)

$Q  = 39   # '
$DQ = 34   # "
$BS = 92   # \
$FS = 47   # /
$AS = 42   # *
$LF = 10   # \n
$LBR = 123; $RBR = 125   # { }
$LPA = 40;  $RPA = 41    # ( )
$LBRK = 91; $RBRK = 93   # [ ]

$files = Get-ChildItem -Recurse -File -Filter *.dart -Path $Root
$results = @()

foreach ($f in $files) {
  $src = [System.IO.File]::ReadAllText($f.FullName)
  $n = $src.Length
  $i = 0
  $line = 1
  $stack = New-Object System.Collections.Stack
  $errors = New-Object System.Collections.ArrayList
  $mode = 'code'

  while ($i -lt $n) {
    $c = [int]$src[$i]
    $c1 = if ($i + 1 -lt $n) { [int]$src[$i + 1] } else { -1 }
    $c2 = if ($i + 2 -lt $n) { [int]$src[$i + 2] } else { -1 }

    if ($c -eq $LF) { $line++ }

    if ($mode -eq 'line') {
      if ($c -eq $LF) { $mode = 'code' }
      $i++; continue
    }
    if ($mode -eq 'block') {
      if ($c -eq $AS -and $c1 -eq $FS) { $mode = 'code'; $i += 2; continue }
      $i++; continue
    }
    if ($mode -eq 'sq') {
      if ($c -eq $BS) { $i += 2; continue }
      if ($c -eq $Q) { $mode = 'code' }
      elseif ($c -eq $LF) { [void]$errors.Add("L${line}: 单引号字符串跨行未闭合"); $mode = 'code' }
      $i++; continue
    }
    if ($mode -eq 'dq') {
      if ($c -eq $BS) { $i += 2; continue }
      if ($c -eq $DQ) { $mode = 'code' }
      elseif ($c -eq $LF) { [void]$errors.Add("L${line}: 双引号字符串跨行未闭合"); $mode = 'code' }
      $i++; continue
    }
    if ($mode -eq 'sq3') {
      if ($c -eq $Q -and $c1 -eq $Q -and $c2 -eq $Q) { $mode = 'code'; $i += 3; continue }
      $i++; continue
    }
    if ($mode -eq 'dq3') {
      if ($c -eq $DQ -and $c1 -eq $DQ -and $c2 -eq $DQ) { $mode = 'code'; $i += 3; continue }
      $i++; continue
    }

    # --- 代码态 ---
    if ($c -eq $FS -and $c1 -eq $FS) { $mode = 'line'; $i += 2; continue }
    if ($c -eq $FS -and $c1 -eq $AS) { $mode = 'block'; $i += 2; continue }
    if ($c -eq $Q  -and $c1 -eq $Q  -and $c2 -eq $Q)  { $mode = 'sq3'; $i += 3; continue }
    if ($c -eq $DQ -and $c1 -eq $DQ -and $c2 -eq $DQ) { $mode = 'dq3'; $i += 3; continue }
    if ($c -eq $Q)  { $mode = 'sq'; $i++; continue }
    if ($c -eq $DQ) { $mode = 'dq'; $i++; continue }

    if ($c -eq $LBR -or $c -eq $LPA -or $c -eq $LBRK) {
      $stack.Push(@($src[$i], $line))
    }
    elseif ($c -eq $RBR -or $c -eq $RPA -or $c -eq $RBRK) {
      $expect = switch ($c) { $RBR { $LBR } $RPA { $LPA } $RBRK { $LBRK } }
      if ($stack.Count -eq 0) {
        [void]$errors.Add("L${line}: 多余的 '$($src[$i])'")
      } else {
        $top = $stack.Pop()
        if ([int]$top[0] -ne $expect) {
          [void]$errors.Add("L${line}: '$($src[$i])' 与第 $($top[1]) 行的 '$($top[0])' 不匹配")
        }
      }
    }
    $i++
  }

  while ($stack.Count -gt 0) {
    $t = $stack.Pop()
    [void]$errors.Add("第 $($t[1]) 行的 '$($t[0])' 未闭合")
  }
  if ($mode -ne 'code' -and $mode -ne 'line') {
    [void]$errors.Add("文件结束时仍处于 $mode 状态")
  }

  $results += [pscustomobject]@{
    file   = $f.FullName.Replace("$Root\", '')
    lines  = ($src -split "`n").Count
    status = if ($errors.Count -eq 0) { 'OK' } else { 'ERROR' }
    detail = ($errors -join ' | ')
  }
}

$results | Sort-Object status, file | Format-Table -AutoSize -Wrap
$bad = @($results | Where-Object { $_.status -eq 'ERROR' })
Write-Output ""
Write-Output "检查文件数: $($results.Count)   错误文件数: $($bad.Count)"
