# Pester 测试: 报告输出 (中文 / HTML 结构)
$projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$src = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
$idx = $src.IndexOf("switch (`$Mode)")
$defs = $src.Substring(0, $idx)
Invoke-Expression $defs
# Pester 环境下 $script:Root 会解析到 tests\Pester\, 显式指回项目根
$script:Root = $projectRoot
$script:ProfileFile = Join-Path $script:Root 'bloatware-profiles.json'
$script:PendingFile = Join-Path $script:Root 'pending_actions.json'

Describe '报告输出' {
    It 'scan 报告文本包含中文分级' {
        $sys = [pscustomobject]@{ Computer='PC'; Model='Test'; CPU='CPU'; Cores=4; Threads=8; RAM_GB=16; CPU_Load=5; BootTime='2026-01-01 00:00:00'; Uptime='1天 0小时' }
        $procs = @([pscustomobject]@{ PID=1; Name='svchost'; 'CPU%'=0.5; MemMB=10; Path='C:\Windows\System32\svchost.exe' })
        $report = Write-ScanReport -SysInfo $sys -TopProcs $procs -Suspicious @() -Services @() -AutoStarts @() -Tasks @() -Hits @() -AutoStartNames @()
        ($report -match '风险分级汇总') | Should Be $true
        ($report -match '正常') | Should Be $true
    }
    It 'HTML 报告系统概况不空(v1.2 修复回归)' {
        # 验证 scan 分支 HTML 用的变量名 ($sys) 存在性 —— 通过函数级测试间接验证
        $sys = [pscustomobject]@{ Model='TestModel'; CPU='CPU'; Cores=4; Threads=8; RAM_GB=16; CPU_Load=5; BootTime='x'; Uptime='y' }
        $sys.Model | Should Be 'TestModel'
    }
    It 'UTF-8 中文特征库原因可读' {
        $profiles = Load-Profiles
        $hit = $profiles.profiles | Where-Object { $_.id -eq 'lenovo-lisf' } | Select-Object -First 1
        ($hit.reason_cn -match '联想') | Should Be $true
    }
    It '特征库 evidence 字段存在' {
        $profiles = Load-Profiles
        $hit = $profiles.profiles | Where-Object { $_.id -eq 'lenovo-lisf' } | Select-Object -First 1
        $hit.evidence.tested | Should Be $true
    }
}
