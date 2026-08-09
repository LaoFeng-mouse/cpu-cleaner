# Pester 测试: 报告输出 (中文 / 结构) (兼容 Pester 3.4 / 5.x)
Describe '报告输出' {
    BeforeEach {
        $projectRoot = if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }
        $src = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
        $idx = $src.IndexOf("switch (`$Mode)")
        if ($idx -lt 0) { throw '主流程 switch 未找到' }
        $defs = $src.Substring(0, $idx)
        $defs = $defs.Replace('$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path', '$script:Root = $projectRoot')
        Invoke-Expression $defs
        # Pester 3.4 与 5.x 断言语法兼容包装
        function Should-Be {
            param([Parameter(ValueFromPipeline)]$actual, $expected)
            process {
                if ((Get-Module Pester).Version.Major -ge 5) { $actual | Should -Be $expected }
                else { $actual | Should Be $expected }
            }
        }
        function Should-Throw {
            param([Parameter(ValueFromPipeline)]$sb)
            process {
                if ((Get-Module Pester).Version.Major -ge 5) { $sb | Should -Throw }
                else { $sb | Should Throw }
            }
        }
        $script:ProfileFile = Join-Path $projectRoot 'bloatware-profiles.json'
    }

    It 'scan 报告文本包含中文分级' {
        $sys = [pscustomobject]@{ Computer='PC'; Model='Test'; CPU='CPU'; Cores=4; Threads=8; RAM_GB=16; CPU_Load=5; BootTime='2026-01-01 00:00:00'; Uptime='1天 0小时' }
        $procs = @([pscustomobject]@{ PID=1; Name='svchost'; 'CPU%'=0.5; MemMB=10; Path='C:\Windows\System32\svchost.exe' })
        $report = Write-ScanReport -SysInfo $sys -TopProcs $procs -Suspicious @() -Services @() -AutoStarts @() -Tasks @() -Hits @() -AutoStartNames @()
        ($report -match '风险分级汇总') | Should-Be $true
        ($report -match '正常') | Should-Be $true
    }
    It 'HTML 报告系统概况字段可用(v1.2 修复回归)' {
        $sys = [pscustomobject]@{ Model='TestModel'; CPU='CPU'; Cores=4; Threads=8; RAM_GB=16; CPU_Load=5; BootTime='x'; Uptime='y' }
        $sys.Model | Should-Be 'TestModel'
    }
    It 'UTF-8 中文特征库原因可读' {
        $profiles = Load-Profiles
        $hit = $profiles.profiles | Where-Object { $_.id -eq 'lenovo-lisf' } | Select-Object -First 1
        ($hit.reason_cn -match '联想') | Should-Be $true
    }
    It '特征库 evidence 字段存在' {
        $profiles = Load-Profiles
        $hit = $profiles.profiles | Where-Object { $_.id -eq 'lenovo-lisf' } | Select-Object -First 1
        $hit.evidence.tested | Should-Be $true
    }
}
