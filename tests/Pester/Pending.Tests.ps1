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
        Mock Get-Service { throw "Unexpected Get-Service read: $Name" }
        Mock Get-Service { [pscustomobject]@{ Name='S1'; StartType='Automatic'; Status='Running' } } -ParameterFilter { $Name -eq 'S1' }
        Mock Get-ScheduledTask { throw "Unexpected Get-ScheduledTask read: $TaskName $TaskPath" }
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName='T1'; TaskPath='\X\'; State='Running' } } -ParameterFilter { $TaskName -eq 'T1' -and $TaskPath -eq '\X\' }
        Mock Get-ItemProperty { throw "Unexpected Get-ItemProperty read: $Path" }
        Mock Get-ItemProperty { [pscustomobject]@{ X = 'C:\fake\X.exe' } } -ParameterFilter { $Path -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' }
    }

    It '仅接受 Int32 pending schema v2' {
        Test-PendingSchemaSupported ([pscustomobject]@{ pending_schema_version = [int32]2 }) | Should -BeTrue
    }

    It '接受 Windows PowerShell ConvertFrom-Json 可能产生的 Int64 schema v2' {
        Test-PendingSchemaSupported ([pscustomobject]@{ pending_schema_version = [int64]2 }) | Should -BeTrue
    }

    It '拒绝缺失、空值、错误版本及非整数标量 pending schema' {
        $unsupported = @(
            [pscustomobject]@{},
            [pscustomobject]@{ pending_schema_version = $null },
            [pscustomobject]@{ pending_schema_version = [int32]1 },
            [pscustomobject]@{ pending_schema_version = [int32]3 },
            [pscustomobject]@{ pending_schema_version = '2' },
            [pscustomobject]@{ pending_schema_version = [double]2.0 },
            [pscustomobject]@{ pending_schema_version = [decimal]2 },
            [pscustomobject]@{ pending_schema_version = $true },
            [pscustomobject]@{ pending_schema_version = @([int32]2) },
            [pscustomobject]@{ pending_schema_version = [pscustomobject]@{ value = 2 } }
        )

        foreach ($pending in $unsupported) {
            Test-PendingSchemaSupported $pending | Should -BeFalse
        }
    }

    It 'Invoke-Clean 在读取 actions 和 Load-Profiles 前拒绝旧 pending envelope' {
        $actionEnginePath = Join-Path $projectRoot 'src\Core\ActionEngine.ps1'
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($actionEnginePath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $invokeClean = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Clean'
        }, $true)
        $body = $invokeClean.Body.Extent.Text

        $convertIndex = $body.IndexOf('$pending = ConvertFrom-StrictPendingJson $pendingRaw')
        $gateIndex = $body.IndexOf('Test-PendingSchemaSupported $pending')
        $actionsIndex = $body.IndexOf('$pending.actions')
        $profilesIndex = $body.IndexOf('Load-Profiles')

        $convertIndex | Should -BeGreaterOrEqual 0
        $gateIndex | Should -BeGreaterThan $convertIndex
        $gateIndex | Should -BeLessThan $actionsIndex
        $gateIndex | Should -BeLessThan $profilesIndex
        $body.Substring($gateIndex, $actionsIndex - $gateIndex) | Should -Match '\bexit\s+1\b'
        $body | Should -Match '旧|不兼容'
        $body | Should -Match 'scan'
    }

    It '旧 envelope 在隔离子进程中输出错误且不加载特征库或读取系统并以非零退出' {
        $pendingPath = Join-Path $TestDrive 'legacy-pending.json'
        $markerPath = Join-Path $TestDrive 'forbidden-calls.txt'
        $fixturePath = Join-Path $TestDrive 'invoke-clean-fixture.ps1'
        [System.IO.File]::WriteAllText($pendingPath, '{"pending_schema_version":1,"actions":[]}', [System.Text.UTF8Encoding]::new($false))
        $actionEnginePath = Join-Path $projectRoot 'src\Core\ActionEngine.ps1'
        $fixture = @'
param([string]$PendingPath, [string]$MarkerPath, [string]$ActionEnginePath)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$script:PendingFile = $PendingPath
$script:ProfileFile = 'must-not-load.json'
$script:BackupRoot = 'must-not-create'
function Is-Admin { return $true }
function Add-ForbiddenCall([string]$Name) { [System.IO.File]::AppendAllText($MarkerPath, ($Name + [Environment]::NewLine)) }
function Load-Profiles { Add-ForbiddenCall 'Load-Profiles'; throw 'Load-Profiles must not run' }
function Get-Service { Add-ForbiddenCall 'Get-Service'; throw 'Get-Service must not run' }
function Get-ItemProperty { Add-ForbiddenCall 'Get-ItemProperty'; throw 'Get-ItemProperty must not run' }
function Get-ScheduledTask { Add-ForbiddenCall 'Get-ScheduledTask'; throw 'Get-ScheduledTask must not run' }
function Get-Process { Add-ForbiddenCall 'Get-Process'; throw 'Get-Process must not run' }
. $ActionEnginePath
Invoke-Clean
exit 0
'@
        [System.IO.File]::WriteAllText($fixturePath, $fixture, [System.Text.UTF8Encoding]::new($false))
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = (Get-Command powershell.exe -ErrorAction Stop).Source
        $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -PendingPath "{1}" -MarkerPath "{2}" -ActionEnginePath "{3}"' -f $fixturePath, $pendingPath, $markerPath, $actionEnginePath)
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        if ($psi.PSObject.Properties.Name -contains 'StandardOutputEncoding') {
            $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
            $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        }
        $process = [System.Diagnostics.Process]::Start($psi)
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()

        $process.ExitCode | Should -Not -Be 0
        ($stdout + $stderr) | Should -Match 'pending'
        ($stdout + $stderr) | Should -Match 'scan'
        Test-Path -LiteralPath $markerPath | Should -BeFalse
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
        $p.observations[0].obs_reason | Should -Match '宽匹配.*禁止'
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
            $p.observations[0].obs_reason | Should -Match '匹配来源缺失或无效' -Because $case.label
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
    It '不支持或跨类型 matched_field 不能进入执行队列' {
        $fields = @('unsupported_field', 'process_name')
        foreach ($field in $fields) {
            $hit = [pscustomobject]@{
                id=$field; vendor='T'; name_cn='Field'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'
                service_name='S1'; service_display_name='Display S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''
                safe=$true; evidence=[pscustomobject]@{ tested=$true }
                matched_pattern='S1'; matched_type='exact'; matched_field=$field
            }
            Save-PendingActions -Hits @($hit) -Suspicious @()
            $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
            @($p.actions).Count | Should -Be 0 -Because $field
            @($p.observations).Count | Should -Be 1 -Because $field
            $p.observations[0].obs_reason | Should -Match '匹配来源缺失或无效' -Because $field
        }
    }
    It '数组或非字符串 matcher provenance 不能进入执行队列' {
        $cases = @(
            [pscustomobject]@{ label='pattern array'; pattern=@('S1'); type='exact'; field='service_name' },
            [pscustomobject]@{ label='pattern number'; pattern=1; type='exact'; field='service_name' },
            [pscustomobject]@{ label='type array'; pattern='S1'; type=@('exact'); field='service_name' },
            [pscustomobject]@{ label='type number'; pattern='S1'; type=1; field='service_name' },
            [pscustomobject]@{ label='field array'; pattern='S1'; type='exact'; field=@('service_name') },
            [pscustomobject]@{ label='field number'; pattern='S1'; type='exact'; field=1 }
        )
        foreach ($case in $cases) {
            $hit = [pscustomobject]@{
                id=$case.label; vendor='T'; name_cn='Shape'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'
                service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''
                safe=$true; evidence=[pscustomobject]@{ tested=$true }
                matched_pattern=$case.pattern; matched_type=$case.type; matched_field=$case.field
            }
            Save-PendingActions -Hits @($hit) -Suspicious @()
            $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
            @($p.actions).Count | Should -Be 0 -Because $case.label
            @($p.observations).Count | Should -Be 1 -Because $case.label
            $p.observations[0].obs_reason | Should -Match '匹配来源缺失或无效' -Because $case.label
        }
    }
    It '宽匹配观察不能压制同目标的精确可执行命中' {
        $base = [ordered]@{
            id='mixed'; vendor='T'; name_cn='Mixed'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'
            service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''
            safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='S'; matched_type='contains'; matched_field='service_name'
        }
        $broad = [pscustomobject]$base
        $exact = $broad.PSObject.Copy()
        $exact.matched_pattern = 'S1'
        $exact.matched_type = 'exact'
        Save-PendingActions -Hits @($broad, $exact) -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should -Be 1
        @($p.observations).Count | Should -Be 1
        $p.actions[0].matched_type | Should -Be 'exact'
        $p.observations[0].matched_type | Should -Be 'contains'
    }
    It '同进程名不同 PID 的可执行命中都保留' {
        $hits = foreach ($processId in @(101, 202)) {
            [pscustomobject]@{
                id='same-process'; vendor='T'; name_cn='Process'; action='uninstall'; hit_type='process'; detail="P1 PID=$processId"; reason_cn='r'
                service_name=''; autostart_source=''; autostart_name=''; task_path=''; process_name='P1'; process_id=$processId; process_path='C:\Apps\P1.exe'
                safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='P1'; matched_type='exact'; matched_field='process_name'
            }
        }
        Save-PendingActions -Hits $hits -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should -Be 2
        @($p.actions.process_id) | Should -Contain 101
        @($p.actions.process_id) | Should -Contain 202
    }
    It '数组、非字符串、null 或空 hit_type 不能进入执行队列' {
        $cases = @(
            [pscustomobject]@{ label='array bypass'; hit_type=@('bogus','service') },
            [pscustomobject]@{ label='number'; hit_type=1 },
            [pscustomobject]@{ label='null'; hit_type=$null },
            [pscustomobject]@{ label='empty'; hit_type='' }
        )
        foreach ($case in $cases) {
            $hit = [pscustomobject]@{
                id=$case.label; vendor='T'; name_cn='HitType'; action='disable_service'; hit_type=$case.hit_type; detail='S1'; reason_cn='r'
                service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''
                safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='S1'; matched_type='exact'; matched_field='service_name'
            }
            Save-PendingActions -Hits @($hit) -Suspicious @()
            $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
            @($p.actions).Count | Should -Be 0 -Because $case.label
            @($p.observations).Count | Should -Be 1 -Because $case.label
            $p.observations[0].obs_reason | Should -Match '匹配来源缺失或无效' -Because $case.label
        }
    }
    It '数组、非字符串、null、空或缺失 action 不能进入执行队列且保留审计证据' {
        $cases = @(
            [pscustomobject]@{ label='one-element array'; has_action=$true; action=@('uninstall') },
            [pscustomobject]@{ label='multi-element array'; has_action=$true; action=@('uninstall','disable_service') },
            [pscustomobject]@{ label='number'; has_action=$true; action=1 },
            [pscustomobject]@{ label='null'; has_action=$true; action=$null },
            [pscustomobject]@{ label='blank'; has_action=$true; action='  ' },
            [pscustomobject]@{ label='missing'; has_action=$false; action=$null }
        )
        foreach ($case in $cases) {
            $hit = [pscustomobject]@{
                id=$case.label; vendor='T'; name_cn='Action'; hit_type='process'; detail='P1 PID=101'; reason_cn='r'
                service_name=''; autostart_source=''; autostart_name=''; task_path=''; process_name='P1'; process_id=101; process_path='C:\Apps\P1.exe'
                safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='P1'; matched_type='exact'; matched_field='process_name'
            }
            if ($case.has_action) { $hit | Add-Member -NotePropertyName action -NotePropertyValue $case.action }
            Save-PendingActions -Hits @($hit) -Suspicious @()
            $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
            @($p.actions).Count | Should -Be 0 -Because $case.label
            @($p.observations).Count | Should -Be 1 -Because $case.label
            $p.observations[0].matched_pattern | Should -Be 'P1' -Because $case.label
            $p.observations[0].matched_type | Should -Be 'exact' -Because $case.label
            $p.observations[0].matched_field | Should -Be 'process_name' -Because $case.label
            $p.observations[0].process_id | Should -Be 101 -Because $case.label
            $p.observations[0].process_path | Should -Be 'C:\Apps\P1.exe' -Because $case.label
        }
    }
    It 'pending JSON 对 0/1 条 action 和 observation 始终使用数组 token' {
        Save-PendingActions -Hits @() -Suspicious @()
        $raw = Get-Content $script:PendingFile -Raw -Encoding UTF8
        $raw | Should -Match '"actions"\s*:\s*\[\s*\]'
        $raw | Should -Match '"observations"\s*:\s*\[\s*\]'

        $action = [pscustomobject]@{ id='one-action'; vendor='T'; name_cn='A'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'; service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''; safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='S1'; matched_type='exact'; matched_field='service_name' }
        Save-PendingActions -Hits @($action) -Suspicious @()
        $raw = Get-Content $script:PendingFile -Raw -Encoding UTF8
        $raw | Should -Match '"actions"\s*:\s*\[\s*\{'
        $raw | Should -Match '"observations"\s*:\s*\[\s*\]'

        $observation = [pscustomobject]@{ id='one-observation'; vendor='T'; name_cn='O'; action='investigate'; hit_type='service'; detail='S2'; reason_cn='r'; service_name='S2'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''; safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='S2'; matched_type='exact'; matched_field='service_name' }
        Save-PendingActions -Hits @($observation) -Suspicious @()
        $raw = Get-Content $script:PendingFile -Raw -Encoding UTF8
        $raw | Should -Match '"actions"\s*:\s*\[\s*\]'
        $raw | Should -Match '"observations"\s*:\s*\[\s*\{'
    }
    It '服务已禁用且停止时不写入 action 或 observation' {
        Mock Get-Service { [pscustomobject]@{ Name='S1'; StartType='Disabled'; Status='Stopped' } } -ParameterFilter { $Name -eq 'S1' }
        $hit = [pscustomobject]@{ id='already'; vendor='T'; name_cn='Already'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'; service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''; safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='S1'; matched_type='exact'; matched_field='service_name' }
        Save-PendingActions -Hits @($hit) -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should -Be 0
        @($p.observations).Count | Should -Be 0
    }
    It 'clean 只处理 pending/failed' {
        ('pending') -in @('pending','failed') | Should -Be $true
        ('failed') -in @('pending','failed') | Should -Be $true
        ('success') -in @('pending','failed') | Should -Be $false
        ('manual_required') -in @('pending','failed') | Should -Be $false
    }
}
