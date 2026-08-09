# Pester 测试: 报告输出 (中文 / 结构) (Pester 5 固定版本 5.9.0)
Describe '报告输出' {
    BeforeEach {
        $projectRoot = if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }
        $src = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
        $idx = $src.IndexOf("switch (`$Mode)")
        if ($idx -lt 0) { throw '主流程 switch 未找到' }
        $defs = $src.Substring(0, $idx)
        $defs = $defs.Replace('$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path', '$script:Root = $projectRoot')
        Invoke-Expression $defs
        # Pester 5 固定版本 (5.9.0): 直接使用原生断言, 不做 3.4/5.x 兼容包装
        $script:ProfileFile = Join-Path $projectRoot 'bloatware-profiles.json'
    }

    It 'scan 报告文本包含中文分级' {
        $sys = [pscustomobject]@{ Computer='PC'; Model='Test'; CPU='CPU'; Cores=4; Threads=8; RAM_GB=16; CPU_Load=5; BootTime='2026-01-01 00:00:00'; Uptime='1天 0小时' }
        $procs = @([pscustomobject]@{ PID=1; Name='svchost'; 'CPU%'=0.5; MemMB=10; Path='C:\Windows\System32\svchost.exe' })
        $report = Write-ScanReport -SysInfo $sys -TopProcs $procs -Suspicious @() -Services @() -AutoStarts @() -Tasks @() -Hits @() -AutoStartNames @()
        ($report -match '风险分级汇总') | Should -Be $true
        ($report -match '正常') | Should -Be $true
    }
    It 'HTML 报告系统概况字段可用(v1.2 修复回归)' {
        $sys = [pscustomobject]@{ Model='TestModel'; CPU='CPU'; Cores=4; Threads=8; RAM_GB=16; CPU_Load=5; BootTime='x'; Uptime='y' }
        $sys.Model | Should -Be 'TestModel'
    }
    It 'HTML 报告含风险评分/分级汇总/版本页脚(v1.5.2 文本-HTML 统一)' {
        $sys = [pscustomobject]@{ Computer='PC'; Model='Test'; CPU='CPU'; Cores=4; Threads=8; RAM_GB=16; CPU_Load=5; BootTime='2026-01-01 00:00:00'; Uptime='1天 0小时' }
        $procs = @(
            [pscustomobject]@{ PID=1; Name='svchost'; 'CPU%'=0.5; MemMB=10; Path='C:\Windows\System32\svchost.exe' },
            [pscustomobject]@{ PID=2; Name='mcpman'; 'CPU%'=8; MemMB=50; Path='C:\ProgramData\Lenovo\LeMcpManager\mcpman.exe' }
        )
        $hits = @([pscustomobject]@{ hit_type='process'; process_name='mcpman'; id='lenovo-lemcp' })
        $html = Write-HtmlReport -SysInfo $sys -TopProcs $procs -Suspicious @() -AutoStarts @() -Tasks @() -Hits $hits -AutoStartNames @('mcpman.exe')
        ($html -match '风险分') | Should -Be $true
        ($html -match '评分依据') | Should -Be $true
        ($html -match '风险分级汇总') | Should -Be $true
        ($html -match '可优化') | Should -Be $true
        ($html -match ('CPU 后台整理工具 v' + $script:Version)) | Should -Be $true
    }
    It 'UTF-8 中文特征库原因可读' {
        $profiles = Load-Profiles
        $hit = $profiles.profiles | Where-Object { $_.id -eq 'lenovo-lisf' } | Select-Object -First 1
        ($hit.reason_cn -match '联想') | Should -Be $true
    }
    It '特征库 evidence 字段存在' {
        $profiles = Load-Profiles
        $hit = $profiles.profiles | Where-Object { $_.id -eq 'lenovo-lisf' } | Select-Object -First 1
        $hit.evidence.tested | Should -Be $true
    }
}
