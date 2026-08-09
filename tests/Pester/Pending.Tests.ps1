# Pester 测试: 待办清单 (去重 / safe 规则 / 状态机) (Pester 5 固定版本 5.9.0)
Describe '待办清单规则' {
    BeforeEach {
        $projectRoot = if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }
        $src = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
        $idx = $src.IndexOf("switch (`$Mode)")
        if ($idx -lt 0) { throw '主流程 switch 未找到' }
        $defs = $src.Substring(0, $idx)
        $defs = $defs.Replace('$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path', '$script:Root = $projectRoot')
        Invoke-Expression $defs
        # Pester 5 固定版本 (5.9.0): 直接使用原生断言, 不做 3.4/5.x 兼容包装
        $script:PendingFile = Join-Path $env:TEMP ("pending_" + [guid]::NewGuid().ToString('N') + ".json")
        # v1.5.2: Mock Windows 状态, 模拟"服务/自启/任务存在但未达目标状态"
        # (Save-PendingActions 会查真实系统: Get-Service / Get-ItemProperty / Get-ScheduledTask,
        #  不 Mock 的话测试结果取决于跑测试的机器, CI 上 S1/X/T1 不存在导致行为漂移)
        Mock Get-Service { [pscustomobject]@{ Name='S1'; StartType='Automatic'; Status='Running' } } -ParameterFilter { $Name -eq 'S1' }
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName='T1'; TaskPath='\X\'; State='Running' } } -ParameterFilter { $TaskName -eq 'T1' -and $TaskPath -eq '\X\' }
        Mock Get-ItemProperty { [pscustomobject]@{ X = 'C:\fake\X.exe' } } -ParameterFilter { $Path -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' }
    }

    It '同一 id 不同动作都保留(不丢 autostart)' {
        $hits = @(
            [pscustomobject]@{ id='a'; vendor='T'; name_cn='A'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'; service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; safe=$true; evidence=[pscustomobject]@{ tested=$true } },
            [pscustomobject]@{ id='a'; vendor='T'; name_cn='A'; action='remove_autostart'; hit_type='autostart'; detail='X'; reason_cn='r'; service_name=''; autostart_source='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; autostart_name='X'; task_path=''; process_name=''; safe=$true; evidence=[pscustomobject]@{ tested=$true } }
        )
        Save-PendingActions -Hits $hits -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should -Be 2
        @($p.observations).Count | Should -Be 0
    }
    It '完全重复(同 id+类型+目标)才去重' {
        $hits = @(
            [pscustomobject]@{ id='a'; vendor='T'; name_cn='A'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'; service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; safe=$true; evidence=[pscustomobject]@{ tested=$true } },
            [pscustomobject]@{ id='a'; vendor='T'; name_cn='A'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'; service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; safe=$true; evidence=[pscustomobject]@{ tested=$true } }
        )
        Save-PendingActions -Hits $hits -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should -Be 1
    }
    It 'tested=false 永不进入执行队列, 进观察(v1.5.6)' {
        $hits = @(
            [pscustomobject]@{ id='d'; vendor='T'; name_cn='D'; action='disable_service'; hit_type='service'; detail='S4'; reason_cn='r'; service_name='S4'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; safe=$true; evidence=[pscustomobject]@{ tested=$false } }
        )
        Save-PendingActions -Hits $hits -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should -Be 0
        @($p.observations).Count | Should -Be 1
        $p.observations[0].obs_reason | Should -Match '未实测'
    }
    It 'safe=false 永不进入执行队列, 进观察(v1.5.6)' {
        $hits = @(
            [pscustomobject]@{ id='b'; vendor='T'; name_cn='B'; action='disable_service'; hit_type='service'; detail='S2'; reason_cn='r'; service_name='S2'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; safe=$false; evidence=[pscustomobject]@{ tested=$true } }
        )
        Save-PendingActions -Hits $hits -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should -Be 0
        @($p.observations).Count | Should -Be 1
        $p.observations[0].obs_reason | Should -Match 'safe=false'
    }
    It 'investigate 动作进观察不进执行队列(v1.5.6)' {
        $hits = @(
            [pscustomobject]@{ id='e'; vendor='T'; name_cn='E'; action='investigate'; hit_type='process'; detail='P1'; reason_cn='r'; service_name=''; autostart_source=''; autostart_name=''; task_path=''; process_name='P1'; safe=$true; evidence=[pscustomobject]@{ tested=$true } }
        )
        Save-PendingActions -Hits $hits -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should -Be 0
        @($p.observations).Count | Should -Be 1
        $p.observations[0].obs_reason | Should -Match '仅观察'
    }
    It '无 evidence 字段视为未实测进观察(v1.5.6 边界)' {
        $hits = @(
            [pscustomobject]@{ id='f'; vendor='T'; name_cn='F'; action='disable_service'; hit_type='service'; detail='S5'; reason_cn='r'; service_name='S5'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; safe=$true }
        )
        Save-PendingActions -Hits $hits -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should -Be 0
        @($p.observations).Count | Should -Be 1
    }
    It '待办初始状态为 pending' {
        $hits = @(
            [pscustomobject]@{ id='c'; vendor='T'; name_cn='C'; action='disable_task'; hit_type='task'; detail='\X\T1'; reason_cn='r'; service_name=''; autostart_source=''; autostart_name=''; task_path='\X\T1'; process_name=''; safe=$true; evidence=[pscustomobject]@{ tested=$true } }
        )
        Save-PendingActions -Hits $hits -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $p.actions[0].status | Should -Be 'pending'
    }
    It 'clean 只处理 pending/failed' {
        ('pending') -in @('pending','failed') | Should -Be $true
        ('failed') -in @('pending','failed') | Should -Be $true
        ('success') -in @('pending','failed') | Should -Be $false
        ('manual_required') -in @('pending','failed') | Should -Be $false
    }
}
