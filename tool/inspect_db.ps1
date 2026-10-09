# 用项目依赖里的 sqlite3 包读取 App 建出的数据库
#
# 用法：
#   .\tool\inspect_db.cmd                          # 看默认位置（私有目录）的库
#   .\tool\inspect_db.cmd D:\某处\qing_notes.sqlite  # 看指定文件
. (Join-Path $PSScriptRoot 'flutter_env.ps1') | Out-Null
$project = Split-Path -Parent $PSScriptRoot
Set-Location $project

# 默认目标：App 的私有目录。Windows 上 path_provider 取的是
# %APPDATA%\<公司名>\<产品名>，再从 exe 版本信息里取，所以这里只能给出
# 「大概是哪」；真正要确认请以设置页「存储位置」显示的路径为准。
$db = $args[0]
if (-not $db) {
  $db = Join-Path $env:APPDATA 'LightNote\LightNote\LightNote\qing_notes.sqlite'
}

if (-not (Test-Path $db)) {
  Write-Output "找不到数据库：$db"
  Write-Output ''
  Write-Output '数据库默认在 App 私有目录，路径以 App 内「设置 → 存储位置」显示的为准。'
  Write-Output '也可以直接指定： .\tool\inspect_db.cmd <文件路径>'
  exit 1
}

Write-Output "检查数据库: $db"
Write-Output ''
dart run tool/inspect_db.dart $db
Write-Output "exit=$LASTEXITCODE"
