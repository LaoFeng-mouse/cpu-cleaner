# Pester 测试: 扫描器与评分
$projectRoot = if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }
$src = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
$idx = $src.IndexOf("switch (`$Mode)")
$defs = $src.Substring(0, $idx)
Invoke-Expression $defs

Describe '扫描器与评分' {
    It '风险分级: 70+ 高度建议处理' {
        Get-RiskLevel 70 | Should Be '高度建议处理'
        Get-RiskLevel 95 | Should Be '高度建议处理'
    }
    It '风险分级: 50-69 可优化' {
        Get-RiskLevel 50 | Should Be '可优化'
        Get-RiskLevel 69 | Should Be '可优化'
    }
    It '风险分级: 30-49 建议观察' {
        Get-RiskLevel 30 | Should Be '建议观察'
    }
    It '风险分级: 0-29 正常' {
        Get-RiskLevel 0 | Should Be '正常'
        Get-RiskLevel 29 | Should Be '正常'
    }
    It 'risk→分数映射' {
        Convert-RiskToScore 'high' | Should Be 80
        Convert-RiskToScore 'medium' | Should Be 55
        Convert-RiskToScore 'low' | Should Be 30
    }
    It '系统进程评分为 0(正常)' {
        $top = @([pscustomobject]@{ PID=1; Name='svchost'; 'CPU%'=1; MemMB=10; Path='C:\Windows\System32\svchost.exe' })
        $r = Get-ProcessRiskScore -proc $top[0] -ProfileHits @() -AutoStartNames @() -TopProcs $top
        $r.Score | Should Be 0
        $r.Level | Should Be '正常'
    }
    It '可疑进程评分 ≥ 50(可优化)' {
        $top = @([pscustomobject]@{ PID=2; Name='mcpman'; 'CPU%'=8; MemMB=50; Path='C:\ProgramData\Lenovo\LeMcpManager\mcpman.exe' })
        $hits = @([pscustomobject]@{ hit_type='process'; process_name='mcpman' })
        $r = Get-ProcessRiskScore -proc $top[0] -ProfileHits $hits -AutoStartNames @('mcpman.exe') -TopProcs $top
        ($r.Score -ge 50) | Should Be $true
    }
    It '自启进程名提取' {
        $autos = @(
            [pscustomobject]@{ Name='SmartConnect'; Value='C:\Program Files\Lenovo\Ready For Assistant\SmartConnect.exe' },
            [pscustomobject]@{ Name='OneDrive'; Value='"C:\Program Files\Microsoft OneDrive\OneDrive.exe" /background' }
        )
        $names = Get-AutoStartProcessNames $autos
        ($names -contains 'SmartConnect.exe') | Should Be $true
        ($names -contains 'OneDrive.exe') | Should Be $true
    }
    It '空进程列表不报错(空机器场景)' {
        $susp = Get-SuspiciousProcesses @()
        @($susp).Count | Should Be 0
    }
}
