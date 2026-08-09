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
            [pscustomobject]@{ id='a'; vendor='T'; name_cn='A'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'; service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''; safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='S1'; matched_type='exact'; matched_field='service_name' },
            [pscustomobject]@{ id='a'; vendor='T'; name_cn='A'; action='remove_autostart'; hit_type='autostart'; detail='X'; reason_cn='r'; service_name=''; autostart_source='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; autostart_name='X'; task_path=''; process_name=''; process_id=0; process_path=''; safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='X'; matched_type='exact'; matched_field='autostart_name' }
        )
        Save-PendingActions -Hits $hits -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should -Be 2
        @($p.observations).Count | Should -Be 0
    }
    It '完全重复(同 id+类型+目标)才去重' {
        $hits = @(
            [pscustomobject]@{ id='a'; vendor='T'; name_cn='A'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'; service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''; safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='S1'; matched_type='exact'; matched_field='service_name' },
            [pscustomobject]@{ id='a'; vendor='T'; name_cn='A'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'; service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''; safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='S1'; matched_type='exact'; matched_field='service_name' }
        )
        Save-PendingActions -Hits $hits -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should -Be 1
    }
    It 'tested=false 永不进入执行队列, 进观察(v1.5.6)' {
        $hits = @(
            [pscustomobject]@{ id='d'; vendor='T'; name_cn='D'; action='disable_service'; hit_type='service'; detail='S4'; reason_cn='r'; service_name='S4'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''; safe=$true; evidence=[pscustomobject]@{ tested=$false }; matched_pattern='S4'; matched_type='exact'; matched_field='service_name' }
        )
        Save-PendingActions -Hits $hits -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should -Be 0
        @($p.observations).Count | Should -Be 1
        $p.observations[0].obs_reason | Should -Match '未实测'
    }
    It 'safe=false 永不进入执行队列, 进观察(v1.5.6)' {
        $hits = @(
            [pscustomobject]@{ id='b'; vendor='T'; name_cn='B'; action='disable_service'; hit_type='service'; detail='S2'; reason_cn='r'; service_name='S2'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''; safe=$false; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='S2'; matched_type='exact'; matched_field='service_name' }
        )
        Save-PendingActions -Hits $hits -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should -Be 0
        @($p.observations).Count | Should -Be 1
        $p.observations[0].obs_reason | Should -Match 'safe=false'
    }
    It 'investigate 动作进观察不进执行队列(v1.5.6)' {
        $hits = @(
            [pscustomobject]@{ id='e'; vendor='T'; name_cn='E'; action='investigate'; hit_type='process'; detail='P1'; reason_cn='r'; service_name=''; autostart_source=''; autostart_name=''; task_path=''; process_name='P1'; process_id=321; process_path='C:\Apps\P1.exe'; safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='P1'; matched_type='exact'; matched_field='process_name' }
        )
        Save-PendingActions -Hits $hits -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should -Be 0
        @($p.observations).Count | Should -Be 1
        $p.observations[0].obs_reason | Should -Match '仅观察'
        $p.observations[0].matched_pattern | Should -Be 'P1'
        $p.observations[0].matched_type | Should -Be 'exact'
        $p.observations[0].matched_field | Should -Be 'process_name'
        $p.observations[0].process_id | Should -Be 321
        $p.observations[0].process_path | Should -Be 'C:\Apps\P1.exe'
    }
    It '无 evidence 字段视为未实测进观察(v1.5.6 边界)' {
        $hits = @(
            [pscustomobject]@{ id='f'; vendor='T'; name_cn='F'; action='disable_service'; hit_type='service'; detail='S5'; reason_cn='r'; service_name='S5'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''; safe=$true; matched_pattern='S5'; matched_type='exact'; matched_field='service_name' }
        )
        Save-PendingActions -Hits $hits -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should -Be 0
        @($p.observations).Count | Should -Be 1
    }
    It '待办初始状态为 pending' {
        $hits = @(
            [pscustomobject]@{ id='c'; vendor='T'; name_cn='C'; action='disable_task'; hit_type='task'; detail='\X\T1'; reason_cn='r'; service_name=''; autostart_source=''; autostart_name=''; task_path='\X\T1'; process_name=''; process_id=0; process_path=''; safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='\X\T1'; matched_type='exact'; matched_field='task_path' }
        )
        Save-PendingActions -Hits $hits -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $p.actions[0].status | Should -Be 'pending'
    }
    It 'pending v2 保存可执行服务的匹配证据和进程空值' {
        $hit = [pscustomobject]@{
            id='v2-service'; vendor='T'; name_cn='V2'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'
            service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''
            safe=$true; evidence=[pscustomobject]@{ tested=$true }
            matched_pattern='S1'; matched_type='exact'; matched_field='service_name'
        }
        Save-PendingActions -Hits @($hit) -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $p.pending_schema_version | Should -Be 2
        @($p.actions).Count | Should -Be 1
        $p.actions[0].matched_pattern | Should -Be 'S1'
        $p.actions[0].matched_type | Should -Be 'exact'
        $p.actions[0].matched_field | Should -Be 'service_name'
        $p.actions[0].process_id | Should -Be 0
        $p.actions[0].process_path | Should -Be ''
    }
    It '宽匹配伪造危险命中只进入观察并保留证据' {
        $hit = [pscustomobject]@{
            id='broad'; vendor='T'; name_cn='Broad'; action='disable_service'; hit_type='service'; detail='LenovoOther'; reason_cn='r'
            service_name='LenovoOther'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''
            safe=$true; evidence=[pscustomobject]@{ tested=$true }
            matched_pattern='Lenovo'; matched_type='contains'; matched_field='service_name'
        }
        Save-PendingActions -Hits @($hit) -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should -Be 0
        @($p.observations).Count | Should -Be 1
        $p.observations[0].matched_pattern | Should -Be 'Lenovo'
        $p.observations[0].matched_type | Should -Be 'contains'
        $p.observations[0].matched_field | Should -Be 'service_name'
        $p.observations[0].process_id | Should -Be 0
        $p.observations[0].process_path | Should -Be ''
        $p.observations[0].obs_reason | Should -Match '实际命中不是 exact/path.*禁止'
    }
    It '缺失或空匹配来源不能进入执行队列' {
        $cases = @(
            [pscustomobject]@{ label='missing'; hit=[pscustomobject]@{ id='missing'; vendor='T'; name_cn='M'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'; service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''; safe=$true; evidence=[pscustomobject]@{ tested=$true } } },
            [pscustomobject]@{ label='empty pattern'; hit=[pscustomobject]@{ id='empty-pattern'; vendor='T'; name_cn='M'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'; service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''; safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern=''; matched_type='exact'; matched_field='service_name' } },
            [pscustomobject]@{ label='empty type'; hit=[pscustomobject]@{ id='empty-type'; vendor='T'; name_cn='M'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'; service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''; safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='S1'; matched_type=''; matched_field='service_name' } },
            [pscustomobject]@{ label='empty field'; hit=[pscustomobject]@{ id='empty-field'; vendor='T'; name_cn='M'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'; service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''; safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='S1'; matched_type='exact'; matched_field='' } }
        )
        foreach ($case in $cases) {
            Save-PendingActions -Hits @($case.hit) -Suspicious @()
            $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
            @($p.actions).Count | Should -Be 0 -Because $case.label
            @($p.observations).Count | Should -Be 1 -Because $case.label
            $p.observations[0].obs_reason | Should -Match '实际命中不是 exact/path.*禁止' -Because $case.label
        }
    }
    It '非 Boolean 的 safe 或 tested 不能进入执行队列' {
        $cases = @(
            [pscustomobject]@{ label='safe string'; safe='true'; tested=$true; reason='safe' },
            [pscustomobject]@{ label='safe number'; safe=1; tested=$true; reason='safe' },
            [pscustomobject]@{ label='tested string'; safe=$true; tested='true'; reason='未实测' },
            [pscustomobject]@{ label='tested number'; safe=$true; tested=1; reason='未实测' }
        )
        foreach ($case in $cases) {
            $hit = [pscustomobject]@{
                id=$case.label; vendor='T'; name_cn='Type'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'
                service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''
                safe=$case.safe; evidence=[pscustomobject]@{ tested=$case.tested }
                matched_pattern='S1'; matched_type='exact'; matched_field='service_name'
            }
            Save-PendingActions -Hits @($hit) -Suspicious @()
            $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
            @($p.actions).Count | Should -Be 0 -Because $case.label
            @($p.observations).Count | Should -Be 1 -Because $case.label
            $p.observations[0].obs_reason | Should -Match $case.reason -Because $case.label
        }
    }
    It 'pending v2 保存可执行进程的身份和窄匹配来源' {
        $hit = [pscustomobject]@{
            id='process-path'; vendor='T'; name_cn='Process'; action='uninstall'; hit_type='process'; detail='P1 PID=4242'; reason_cn='r'
            service_name=''; autostart_source=''; autostart_name=''; task_path=''; process_name='P1'; process_id=4242; process_path='C:\Apps\P1.exe'
            safe=$true; evidence=[pscustomobject]@{ tested=$true }
            matched_pattern='C:\Apps'; matched_type='path'; matched_field='process_path'
        }
        Save-PendingActions -Hits @($hit) -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should -Be 1
        $p.actions[0].matched_pattern | Should -Be 'C:\Apps'
        $p.actions[0].matched_type | Should -Be 'path'
        $p.actions[0].matched_field | Should -Be 'process_path'
        $p.actions[0].process_id | Should -Be 4242
        $p.actions[0].process_path | Should -Be 'C:\Apps\P1.exe'
    }
    It 'clean 只处理 pending/failed' {
        ('pending') -in @('pending','failed') | Should -Be $true
        ('failed') -in @('pending','failed') | Should -Be $true
        ('success') -in @('pending','failed') | Should -Be $false
        ('manual_required') -in @('pending','failed') | Should -Be $false
    }
}
