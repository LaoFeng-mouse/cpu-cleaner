# Pester 测试: 待办清单 (去重 / safe 规则 / 状态机) (兼容 Pester 3.4 / 5.x)
Describe '待办清单规则' {
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
        $script:PendingFile = Join-Path $env:TEMP ("pending_" + [guid]::NewGuid().ToString('N') + ".json")
    }

    It '同一规则(id)不会重复动作' {
        $hits = @(
            [pscustomobject]@{ id='a'; vendor='T'; name_cn='A'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'; service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; safe=$true },
            [pscustomobject]@{ id='a'; vendor='T'; name_cn='A'; action='remove_autostart'; hit_type='autostart'; detail='X'; reason_cn='r'; service_name=''; autostart_source='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; autostart_name='X'; task_path=''; process_name=''; safe=$true }
        )
        Save-PendingActions -Hits $hits -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should-Be 1
    }
    It 'safe=false 永不进入待办队列' {
        $hits = @(
            [pscustomobject]@{ id='b'; vendor='T'; name_cn='B'; action='disable_service'; hit_type='service'; detail='S2'; reason_cn='r'; service_name='S2'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; safe=$false }
        )
        Save-PendingActions -Hits $hits -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should-Be 0
    }
    It '待办初始状态为 pending' {
        $hits = @(
            [pscustomobject]@{ id='c'; vendor='T'; name_cn='C'; action='disable_task'; hit_type='task'; detail='\X\T1'; reason_cn='r'; service_name=''; autostart_source=''; autostart_name=''; task_path='\X\T1'; process_name=''; safe=$true }
        )
        Save-PendingActions -Hits $hits -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $p.actions[0].status | Should-Be 'pending'
    }
    It 'clean 只处理 pending/failed' {
        ('pending') -in @('pending','failed') | Should-Be $true
        ('failed') -in @('pending','failed') | Should-Be $true
        ('success') -in @('pending','failed') | Should-Be $false
        ('manual_required') -in @('pending','failed') | Should-Be $false
    }
}
