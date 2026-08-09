# GUI 无窗口测试 runner — 必须用 powershell -STA 运行 (WPF XamlReader.Load 需要 STA)
# CI 调用: powershell -STA -NoProfile -ExecutionPolicy Bypass -File tests/run-gui-tests.ps1
$ErrorActionPreference = 'Stop'
$env:SHUSHU_CLEANER_TEST = '1'
$projectRoot = Split-Path $PSScriptRoot -Parent
Import-Module Pester -RequiredVersion 5.9.0
$r = Invoke-Pester (Join-Path $PSScriptRoot 'Gui.Tests.ps1') -PassThru
if ($r.FailedCount -gt 0) { throw "GUI tests failed: $($r.FailedCount)" }
