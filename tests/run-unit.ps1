# 单元测试 runner: 只加载 cpu-cleaner.ps1 的函数定义(不含主流程), 跑全部测试
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$src = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8

# 截取主流程 switch 之前的部分 (param + 变量 + 全部函数定义)
$idx = $src.IndexOf("switch (`$Mode)")
if ($idx -lt 0) { Write-Host '未找到主流程 switch, 无法截取' -ForegroundColor Red; exit 1 }
$defs = $src.Substring(0, $idx)
# v1.7.0 模块化: 截取段里的 dot-source 在截取环境下 $script:Root 指向 tests 目录, 路径错误
# 删除 dot-source 块, 改为下方按依赖顺序点源 src/Core/
$defs = $defs -replace "(?s)# ---------- v1\.7\.0 模块化.*?\n\}", ''
Invoke-Expression $defs
foreach ($f in @('Utils','ProfileEngine','Scanner','RiskEngine','ReportEngine','ActionEngine','BackupManager')) {
    . (Join-Path $projectRoot ('src\Core\' + $f + '.ps1'))
}

Write-Host '===== 逻辑测试 (映射/状态机/safe) =====' -ForegroundColor Cyan
$test1 = Get-Content (Join-Path $PSScriptRoot 'unit-logic.ps1') -Raw -Encoding UTF8
try { Invoke-Expression $test1 } catch { Write-Host "逻辑测试失败: $_" -ForegroundColor Red; exit 1 }

Write-Host "`n===== Schema 测试 (特征库校验) =====" -ForegroundColor Cyan
$test2 = Get-Content (Join-Path $PSScriptRoot 'schema-tests.ps1') -Raw -Encoding UTF8
try { Invoke-Expression $test2 } catch { Write-Host "Schema 测试失败: $_" -ForegroundColor Red; exit 1 }

Write-Host "`n===== 全部测试通过 =====" -ForegroundColor Green
