# v1.2 单元测试 runner: 只加载 cpu-cleaner.ps1 的函数定义(不含主流程), 跑纯逻辑测试
$ErrorActionPreference = 'Stop'
$src = Get-Content 'D:\34615\CPU后台整理工具\cpu-cleaner.ps1' -Raw -Encoding UTF8

# 截取主流程 switch 之前的部分 (param + 变量 + 全部函数定义)
$idx = $src.IndexOf("switch (`$Mode)")
if ($idx -lt 0) { Write-Host '未找到主流程 switch, 无法截取' -ForegroundColor Red; exit 1 }
$defs = $src.Substring(0, $idx)

Invoke-Expression $defs

# 跑单元测试
$test = Get-Content 'D:\34615\CPU后台整理工具\tests\unit-logic.ps1' -Raw -Encoding UTF8
Invoke-Expression $test
