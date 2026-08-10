# Pester 测试: 扫描器与评分 (Pester 5 固定版本 5.9.0)
Describe '扫描器与评分' {
    BeforeEach {
        $projectRoot = if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }
        $src = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
        $idx = $src.IndexOf("switch (`$Mode)")
        if ($idx -lt 0) { throw '主流程 switch 未找到' }
        $defs = $src.Substring(0, $idx)
        $defs = $defs.Replace('$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path', '$script:Root = $projectRoot')
        Invoke-Expression $defs
        # Pester 5 固定版本 (5.9.0): 直接使用原生断言, 不做 3.4/5.x 兼容包装
    }

    It '风险分级: 70+ 高度建议处理' {
        Get-RiskLevel 70 | Should -Be '高度建议处理'
        Get-RiskLevel 95 | Should -Be '高度建议处理'
    }
    It '风险分级: 50-69 可优化' {
        Get-RiskLevel 50 | Should -Be '可优化'
        Get-RiskLevel 69 | Should -Be '可优化'
    }
    It '风险分级: 30-49 建议观察' {
        Get-RiskLevel 30 | Should -Be '建议观察'
    }
    It '风险分级: 0-29 正常' {
        Get-RiskLevel 0 | Should -Be '正常'
        Get-RiskLevel 29 | Should -Be '正常'
    }
    It 'risk→分数映射' {
        Convert-RiskToScore 'high' | Should -Be 80
        Convert-RiskToScore 'medium' | Should -Be 55
        Convert-RiskToScore 'low' | Should -Be 30
    }
    It '系统进程评分为 0(正常)' {
        $top = @([pscustomobject]@{ PID=1; Name='svchost'; 'CPU%'=1; MemMB=10; Path='C:\Windows\System32\svchost.exe' })
        $r = Get-ProcessRiskScore -proc $top[0] -ProfileHits @() -AutoStartNames @() -TopProcs $top
        $r.Score | Should -Be 0
        $r.Level | Should -Be '正常'
    }
    It '可疑进程评分 >= 50(可优化)' {
        $top = @([pscustomobject]@{ PID=2; Name='mcpman'; 'CPU%'=8; MemMB=50; Path='C:\ProgramData\Lenovo\LeMcpManager\mcpman.exe' })
        $hits = @([pscustomobject]@{ hit_type='process'; process_name='mcpman' })
        $r = Get-ProcessRiskScore -proc $top[0] -ProfileHits $hits -AutoStartNames @('mcpman.exe') -TopProcs $top
        ($r.Score -ge 50) | Should -Be $true
    }
    It '自启进程名提取(标准化为无扩展名小写)' {
        $autos = @(
            [pscustomobject]@{ Name='SmartConnect'; Value='C:\Program Files\Lenovo\Ready For Assistant\SmartConnect.exe' },
            [pscustomobject]@{ Name='OneDrive'; Value='"C:\Program Files\Microsoft OneDrive\OneDrive.exe" /background' }
        )
        $names = Get-AutoStartProcessNames $autos
        ($names -contains 'smartconnect') | Should -Be $true
        ($names -contains 'onedrive') | Should -Be $true
        # v1.5.1 标准化契约: 不保留扩展名/大小写
        ($names -contains 'SmartConnect.exe') | Should -Be $false
    }
    It '空进程列表不报错(空机器场景)' {
        $susp = Get-SuspiciousProcesses @()
        @($susp).Count | Should -Be 0
    }
    It '持续占用加分 (v1.5.7): 5 次采样中 3 次 ≥5%' {
        $top = @([pscustomobject]@{ PID=9; Name='updater'; 'CPU%'=4.2; CPUPeak=38.2; SamplesHigh=3; Samples=5; ChildCount=17; MemMB=428; Path='C:\Program Files\X\updater.exe' })
        $r = Get-ProcessRiskScore -proc $top[0] -ProfileHits @() -AutoStartNames @() -TopProcs $top
        ($r.Reasons -match '持续占用3/5') | Should -Be $true
    }
    It '持续占用不足不加分: 5 次采样中 2 次 (阈值一半)' {
        $top = @([pscustomobject]@{ PID=9; Name='updater'; 'CPU%'=2.1; CPUPeak=9.0; SamplesHigh=2; Samples=5; ChildCount=0; MemMB=50; Path='C:\Program Files\X\updater.exe' })
        $r = Get-ProcessRiskScore -proc $top[0] -ProfileHits @() -AutoStartNames @() -TopProcs $top
        ($r.Reasons -match '持续占用') | Should -Be $false
    }
    It '旧字段兼容: proc 无 SamplesHigh/Samples 不加持续分' {
        $top = @([pscustomobject]@{ PID=1; Name='svchost'; 'CPU%'=0.5; MemMB=10; Path='C:\Windows\System32\svchost.exe' })
        $r = Get-ProcessRiskScore -proc $top[0] -ProfileHits @() -AutoStartNames @() -TopProcs $top
        ($r.Reasons -match '持续占用') | Should -Be $false
    }
    It 'emits scan phases in the same order as the read-only pipeline' {
        $source = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
        $markers = @(
            '读取系统信息', '检查高占用进程', '检查系统服务', '检查启动项',
            '检查计划任务', '匹配安全规则', '生成扫描报告'
        )
        $last = -1
        foreach ($marker in $markers) {
            $index = $source.IndexOf($marker, [System.StringComparison]::Ordinal)
            $index | Should -BeGreaterThan $last
            $last = $index
        }
    }
}
